--!strict
--[[
	Full-screen effects the client owns: the flashbang blind, and the frag's
	STUNNED indicator.

	WHY THE VIEW CONE IS TESTED HERE AND NOT ON THE SERVER

	The server has already decided who was close enough and who had an
	unobstructed line to the blast -- it can check both, so it does
	(Net.flashDetonated's own comment). The one test it cannot make is whether
	the blast was in front of the CAMERA. The server holds the character's
	facing, and in a first-person game those are two different directions: a
	player who stands still while looking behind them is doing a normal thing,
	and a cone drawn from the torso would blind them for a blast they never
	saw, then fail to blind them for one they stared straight at.

	That split is honest rather than lax. No server can force a client to
	render white pixels, so a client that lies about its cone has achieved
	exactly what dropping the packet would already have achieved. Everything
	that CAN be enforced -- who is in range, who is behind a wall -- is
	enforced where it counts.

	WHY THIS CONTROLLER BUILDS A GUI WHEN NOTHING ELSE MAY

	Studio owns the screens and code finds them. The flash is the sanctioned
	exception, for a structural reason rather than convenience: it is not a
	screen. It is one coloured rectangle that has to sit above every screen,
	including screens authored after this file was written. Parenting it under
	StarterGui.Screens would enrol it in UIController's exclusive swap, where
	opening the Settings menu would close the blind -- which is both a bug and
	a free counter to a grenade.

	The stun indicator is built here for the same reason. A player frozen by a
	frag who opened Settings must not make the warning go away, and nothing
	authored should be able to draw over it.

	There is no per-character or per-round state below to leak: one ScreenGui
	per effect for the session, at most one pending hold and one tween, each
	replaced rather than accumulated.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local DataController = require(script.Parent.DataController)
local Log = require(ReplicatedStorage.Shared.Log)
local Motion = require(script.Parent.Parent.UI.Motion)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("EffectsController")

local player = Players.LocalPlayer

--[[
	Well clear of every authored screen (the highest today is Results at 9), so
	a screen added next month cannot quietly start drawing over a blind.

	NOT 1000, which is deliberate: DevConsoleController already builds its own
	ScreenGui at exactly that value (DevConsoleController.luau:386). Two
	ScreenGuis sharing a DisplayOrder are ordered by sibling order, not by the
	number, so a tie here would render the blind above the console on some boots
	and below it on others -- and it would only ever be seen by a developer
	testing grenades with the console open, which is the worst audience for a
	non-deterministic bug. A distinct, higher number makes the contract's "must
	sit above everything" an actual guarantee rather than a coin flip.
]]
local FLASH_DISPLAY_ORDER = 10000

--[[
	Half the cone, pre-cosined, so each blast costs one dot product and one
	compare instead of a math.acos.

	Config.Flash.ViewConeDegrees is the FULL width -- its own comment says so --
	so 120 means 60 degrees either side of the look vector. Halving it here
	once is the only place that reading is encoded.
]]
local HALF_CONE_COSINE = math.cos(math.rad(Config.Flash.ViewConeDegrees / 2))

-- Closer than this and the blast is effectively at the eye: there is no
-- meaningful direction left to test, only a division to avoid.
local MIN_CONE_DISTANCE = 0.05

local FLASH_WHITE = Color3.new(1, 1, 1)
local FLASH_BLACK = Color3.new(0, 0, 0)

--[[
	The fade eases IN, and that is the whole feel of the effect. A linear clear
	reads as fog lifting; Quad In holds the player at near-opaque and then lets
	go quickly at the end, which is what being flashed actually does.

	The duration is Config's, untouched by the dark-flash setting -- that swap
	changes the colour and nothing else.
]]
local FADE_INFO = TweenInfo.new(Config.Flash.FadeDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

type Overlay = {
	gui: ScreenGui,
	fill: Frame,
}

--[[
	One below the flash, so a flashbang landing during a stun still whites
	everything out, and above every authored screen for the reason
	FLASH_DISPLAY_ORDER gives.
]]
local STUN_DISPLAY_ORDER = FLASH_DISPLAY_ORDER - 1
-- The stun effect's yellow (GrenadeService), so the frozen player and the
-- people looking at them see the same colour mean the same thing.
local STUN_COLOR = Color3.fromRGB(255, 221, 64)

type StunOverlay = {
	gui: ScreenGui,
	label: TextLabel,
}

--[[
	The shock's warning: the same shape as the stun's, in the shock grenade's
	electric blue, one DisplayOrder below it and with its label just under the
	stun's, so a player both stunned and shocked reads both.
]]
local SHOCK_DISPLAY_ORDER = STUN_DISPLAY_ORDER - 1
local SHOCK_COLOR = Color3.fromRGB(90, 190, 255)

local EffectsController = {}

-- Resolved in Start(). nil until then, because WaitForChild yields and Init()
-- may not.
local playerGui: Instance? = nil
local overlay: Overlay? = nil

-- The hold between "fully opaque" and "start fading". Kept so a second blast
-- can cancel it rather than let it fire against an effect that has restarted.
local holdThread: thread? = nil
local fadeHandle: Motion.Handle? = nil

--[[
	Mirrors the persisted accessibility preference.

	Read at the START of a flash only. Applying a colour change to a blind
	already in progress would turn a settings toggle into a second, unasked-for
	effect in the middle of a fight.
]]
local darkFlash = false

--[[
	The one ScreenGui, created once and reused.

	It rebuilds itself if it ever loses its parent, which is cheap insurance
	against StarterGui.ResetPlayerGuiOnSpawn clearing PlayerGui out from under
	us -- and the next flash is the only place that failure would ever show.
]]
local function ensureOverlay(): Overlay?
	local parent = playerGui
	if parent == nil then
		-- Start() has not resolved PlayerGui yet. Only reachable in the first
		-- frames after joining, where there is nothing on screen to obscure.
		log.debug("flash arrived before PlayerGui resolved -- ignored")
		return nil
	end

	local current = overlay
	if current ~= nil and current.gui.Parent == parent then
		return current
	end
	if current ~= nil then
		current.gui:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "FlashOverlay"
	gui.DisplayOrder = FLASH_DISPLAY_ORDER
	gui.IgnoreGuiInset = true
	--[[
		ResetOnSpawn defaults to TRUE, and a ScreenGui a script created in
		PlayerGui is destroyed by it on the next respawn with nothing in
		StarterGui to clone it back. In a game whose core loop is dying, that
		means the flash works exactly once per session -- a bug that surfaces
		an hour into a playtest as "flashbangs stopped doing anything".
	]]
	gui.ResetOnSpawn = false
	gui.Enabled = false

	local fill = Instance.new("Frame")
	fill.Name = "FlashFill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BorderSizePixel = 0
	fill.BackgroundTransparency = 1
	--[[
		Not Active, not Selectable, and deliberately not a button: a blinded
		player is still typing a code and still pressing buttons they remember
		the position of. An overlay that swallowed input would make the flash
		disable the game rather than obscure it.
	]]
	fill.Active = false
	fill.Selectable = false
	fill.Parent = gui

	gui.Parent = parent

	local built: Overlay = {
		gui = gui,
		fill = fill,
	}
	overlay = built
	return built
end

--[[
	Drops whatever the previous flash still had in flight.

	task.cancel throws on a thread that has already finished, so only a hold
	still waiting out its delay may be cancelled -- and Motion's cancel halts
	the tween in place without running its completion callback, which is what
	stops a stale "hide the overlay" from firing a frame into the new flash.
]]
local function cancelPending()
	local thread = holdThread
	holdThread = nil
	if thread ~= nil and coroutine.status(thread) == "suspended" then
		task.cancel(thread)
	end

	local handle = fadeHandle
	fadeHandle = nil
	if handle ~= nil then
		handle.cancel()
	end
end

local function playFlash()
	local target = ensureOverlay()
	if target == nil then
		return
	end

	--[[
		Restart, never stack. Two blasts a quarter of a second apart are ONE
		blind that lasts longer, not two overlays whose transparencies multiply
		into a grey nobody chose -- and stacking instances would also leave a
		second ScreenGui behind per grenade for the rest of the round.
	]]
	cancelPending()

	target.fill.BackgroundColor3 = if darkFlash then FLASH_BLACK else FLASH_WHITE
	target.fill.BackgroundTransparency = 0
	target.gui.Enabled = true

	holdThread = task.delay(Config.Flash.FullDuration, function()
		holdThread = nil
		fadeHandle = Motion.tween(target.fill, { BackgroundTransparency = 1 }, FADE_INFO, function()
			fadeHandle = nil
			-- Disabled, not merely transparent: a fully clear full-screen frame
			-- is still a layer the renderer composites on every frame of the
			-- round that follows.
			target.gui.Enabled = false
		end)
	end)
end

--[[
	The client half of the flash decision.

	closeRange is the server's verdict for a blast at your feet: it blinds
	whichever way you are facing, so there is no direction worth testing and
	this returns before touching the camera at all.
]]
local function shouldBlind(position: Vector3, closeRange: boolean): boolean
	if closeRange then
		return true
	end

	local camera = Workspace.CurrentCamera
	if camera == nil then
		-- Nothing is being rendered, so there is nothing to blind. Spend the
		-- packet rather than queue an effect for a camera that may never come.
		return false
	end

	local eye = camera.CFrame
	local offset = position - eye.Position
	local distance = offset.Magnitude
	if distance <= MIN_CONE_DISTANCE then
		return true
	end

	--[[
		offset / distance rather than offset.Unit, and the distance guard above
		rather than a NaN test below.

		Unit divides by a magnitude it recomputes internally, and at zero length
		hands back a vector of NaNs; the dot product is then NaN, and NaN fails
		every comparison silently, so a blast at the exact camera position would
		be discarded as "outside the cone" (quality-gate.md trap #8). Rejecting
		the degenerate distance first means the value below cannot be NaN at
		all, which is a stronger guarantee than checking for one afterwards.
	]]
	return eye.LookVector:Dot(offset / distance) >= HALF_CONE_COSINE
end

local stunOverlay: StunOverlay? = nil
-- Server time the current stun ends, and the loop counting down to it.
local stunEndsAt = 0
local stunConnection: RBXScriptConnection? = nil

--[[
	This controller is the client's one answer to "am I stunned?", because it
	is the one that hears Net.stunned and Net.killed. TypeModeController asks
	here rather than tracking its own copy, so the countdown on screen and the
	locked keypad cannot disagree about when the stun ends.
]]
local stunListeners: { (stunned: boolean) -> () } = {}
local stunned = false

local function setStunned(value: boolean)
	if stunned == value then
		return
	end
	stunned = value
	for _, listener in stunListeners do
		task.spawn(listener, value)
	end
end

--[[
	A coloured edge around the whole screen with a countdown label: the stun's
	and the shock's warning. The player can still see the fight, which is the
	point, but cannot miss the effect.
]]
local function buildTimedOverlay(
	parent: Instance,
	name: string,
	color: Color3,
	displayOrder: number,
	labelY: number
): StunOverlay
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.DisplayOrder = displayOrder
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.Enabled = false

	local frame = Instance.new("Frame")
	frame.Name = "Edge"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	frame.Active = false
	frame.Parent = gui

	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = 10
	stroke.Transparency = 0.25
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame

	-- Below the crosshair, above the toolbar: where the eye already is, not
	-- over the thing the player is trying to read.
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, labelY)
	label.Size = UDim2.fromScale(0.3, 0.05)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.4
	label.Text = ""
	label.Parent = gui

	gui.Parent = parent
	return { gui = gui, label = label }
end

-- Same shape and the same ResetOnSpawn reasoning as ensureOverlay.
local function ensureStunOverlay(): StunOverlay?
	local parent = playerGui
	if parent == nil then
		return nil
	end

	local current = stunOverlay
	if current ~= nil and current.gui.Parent == parent then
		return current
	end
	if current ~= nil then
		current.gui:Destroy()
	end

	local built = buildTimedOverlay(parent, "StunOverlay", STUN_COLOR, STUN_DISPLAY_ORDER, 0.64)
	stunOverlay = built
	return built
end

local function stopStun()
	local connection = stunConnection
	stunConnection = nil
	if connection ~= nil then
		connection:Disconnect()
	end
	local current = stunOverlay
	if current ~= nil then
		current.gui.Enabled = false
	end
	setStunned(false)
end

local function playStun(endsAt: number)
	-- NaN passes every comparison below and would pin the overlay up forever
	-- (quality-gate trap #8).
	if endsAt ~= endsAt then
		return
	end
	-- Restarted, not added to: a second frag resets the stun to its full
	-- length on the server (SprintService.stun), and the countdown follows.
	stunEndsAt = endsAt
	setStunned(true)

	local target = ensureStunOverlay()
	if target == nil then
		return
	end
	target.gui.Enabled = true

	if stunConnection ~= nil then
		return
	end
	stunConnection = RunService.Heartbeat:Connect(function()
		local remaining = stunEndsAt - Workspace:GetServerTimeNow()
		if remaining <= 0 then
			stunEndsAt = 0
			stopStun()
			return
		end
		target.label.Text = string.format("STUNNED %.1f", remaining)
	end)
end

local shockOverlay: StunOverlay? = nil
local shockEndsAt = 0
local shockConnection: RBXScriptConnection? = nil

local function ensureShockOverlay(): StunOverlay?
	local parent = playerGui
	if parent == nil then
		return nil
	end

	local current = shockOverlay
	if current ~= nil and current.gui.Parent == parent then
		return current
	end
	if current ~= nil then
		current.gui:Destroy()
	end

	local built = buildTimedOverlay(parent, "ShockOverlay", SHOCK_COLOR, SHOCK_DISPLAY_ORDER, 0.69)
	shockOverlay = built
	return built
end

local function stopShock()
	shockEndsAt = 0
	local connection = shockConnection
	shockConnection = nil
	if connection ~= nil then
		connection:Disconnect()
	end
	local current = shockOverlay
	if current ~= nil then
		current.gui.Enabled = false
	end
end

-- The shock's countdown, restarted (not extended) by a second shock, like
-- the stun's -- SprintService.slow restarts the slow the same way.
local function playShock(endsAt: number)
	if endsAt ~= endsAt then
		return
	end
	shockEndsAt = endsAt

	local target = ensureShockOverlay()
	if target == nil then
		return
	end
	target.gui.Enabled = true

	if shockConnection ~= nil then
		return
	end
	shockConnection = RunService.Heartbeat:Connect(function()
		local remaining = shockEndsAt - Workspace:GetServerTimeNow()
		if remaining <= 0 then
			stopShock()
			return
		end
		target.label.Text = string.format("SHOCKED -- NO SPRINT %.1f", remaining)
	end)
end

function EffectsController.isStunned(): boolean
	return stunned
end

-- Fires with true when a stun starts and false when it ends or the player
-- dies. Not on a restart: a second frag keeps you stunned, it does not
-- un-stun you in between.
function EffectsController.onStunChanged(listener: (stunned: boolean) -> ())
	table.insert(stunListeners, listener)
end

function EffectsController.Init()
	--[[
		Registered in Init, not Start. A grenade already in the air when we join
		detonates on the server's schedule, not ours, and a ByteNet listener
		that does not exist yet drops the packet rather than queueing it -- the
		same trap DataController.luau documents for Replica.OnNew, and the
		reason Init and Start are separate phases.
	]]
	Net.flashDetonated.listen(function(data)
		if not shouldBlind(data.position, data.closeRange) then
			return
		end
		playFlash()
	end)

	-- Init for the same reason as the flash: a frag can go off before this
	-- client's Start has run.
	Net.stunned.listen(function(data)
		playStun(data.endsAt)
	end)
	Net.shocked.listen(function(data)
		playShock(data.endsAt)
	end)

	-- Dying ends the stun and the shock with the body (SprintService resets
	-- both on the next spawn), so neither warning may sit over the killcam.
	Net.killed.listen(function()
		stunEndsAt = 0
		stopStun()
		stopShock()
	end)
end

function EffectsController.Start()
	-- WaitForChild, not a direct index: PlayerGui arrives by replication a
	-- little after the player does, so a direct index is a race that merely
	-- happens to pass on a fast machine.
	playerGui = player:WaitForChild("PlayerGui")

	--[[
		The accessibility swap comes from the profile, never from a packet. It
		is a persisted preference, and observe fires once with the current value
		AND on every change, so a rejoin and a mid-session toggle take the same
		path (NETWORKING-AND-DATA.md, "which pipe?").

		`value == true` rather than a truthiness test: nil here is a profile
		written before the setting existed, which means "no" and is not worth a
		warning.
	]]
	DataController.observe({ "Settings", "DarkFlashEffect" }, function(value)
		darkFlash = value == true
	end)

	-- Built up front so the first grenade is not also the first Instance.new.
	-- Creating and parenting a ScreenGui mid-blast costs the player frames of
	-- clear vision from the effect meant to take it away.
	ensureOverlay()
	ensureStunOverlay()
	ensureShockOverlay()
end

return EffectsController
