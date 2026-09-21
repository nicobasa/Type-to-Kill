--!strict
--[[
	The typing path: open the panel, type a four-digit code, send it.

	This is the one input in the game that has to feel instant, so two
	properties come before everything else here:

	  1. A key press never waits on the server. Digits render locally, and a
	     rejection clears them the moment it lands. There is no "busy" state in
	     between where the player has typed something and is not allowed to type
	     the next thing -- a miss costs four keystrokes and nothing else.
	  2. The keys are OURS while the panel is open. ContextActionService binds
	     them above the default priority and sinks them, so `1` is a digit and
	     not ToolbarController's slot 1 (Binds.SLOT_1 is the same physical key),
	     and nothing leaks into chat or movement. The binds come off again on
	     close: the number row belongs to the rest of the game the instant the
	     panel goes, and that half is what makes sinking them safe at all.

	Studio owns the panel (ARCHITECTURE.md, "The map"). This drives
	Screens.TypeMode; it never builds it. With no panel authored it warns once
	and stays idle rather than erroring on every T.

	The code is a STRING here and everywhere else. "0047" is a legal code and
	tonumber("0047") is 47 -- the leading zeros ARE the identity (Config.Code
	says the same thing to the server), so nothing in this file parses one as a
	number.
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Binds = require(script.Parent.Parent.UI.Binds)
local Config = require(ReplicatedStorage.Shared.Config)
local Device = require(script.Parent.Parent.UI.Device)
local Log = require(ReplicatedStorage.Shared.Log)
local MatchController = require(script.Parent.MatchController)
local Motion = require(script.Parent.Parent.UI.Motion)
local Net = require(ReplicatedStorage.Shared.Net)
local UIController = require(script.Parent.UIController)

local log = Log.new("TypeModeController")

local player = Players.LocalPlayer

local SCREENS_FOLDER = "Screens"
local SCREEN_NAME = "TypeMode"
local HUD_SCREEN_NAME = "HUD"

-- Bounded, both of them: a renamed or unauthored element has to surface as one
-- warning, not as a Start() thread that waits for the rest of the session.
local SCREEN_TIMEOUT = 10
local ELEMENT_TIMEOUT = 5

local TOGGLE_ACTION = "TypeModeToggle"
local INPUT_ACTION = "TypeModeInput"

--[[
	Above the default BindAction priority (2000). ToolbarController binds One
	and Two for its slots and StaminaController binds LeftShift; while the panel
	is up those presses are digits, or nothing. Settling that with priority plus
	Sink keeps it at the input layer instead of asking every other controller to
	remember to check whether someone is typing.

	The toggle sits at the default priority: it is the only claim on T, and
	nothing else wants it.
]]
local INPUT_PRIORITY = Enum.ContextActionPriority.High.Value
local TOGGLE_PRIORITY = Enum.ContextActionPriority.Medium.Value

local KEY_VALUE_ATTRIBUTE = "KeyValue"
local CLEAR_VALUE = "CLR"
local SUBMIT_VALUE = "OK"

-- The rejection flash. Loud for a frame, gone in a quarter second -- it has to
-- read as "not that one" without being something the player waits out.
local REJECT_COLOR = Color3.fromRGB(226, 72, 72)

--[[
	Every key that produces a digit, including the numeric keypad. This is a
	typing game: a player with a number pad will use it, and finding out that
	half their keyboard is dead mid-round is not a discovery worth making.
]]
local DIGIT_KEYS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.Zero] = "0",
	[Enum.KeyCode.One] = "1",
	[Enum.KeyCode.Two] = "2",
	[Enum.KeyCode.Three] = "3",
	[Enum.KeyCode.Four] = "4",
	[Enum.KeyCode.Five] = "5",
	[Enum.KeyCode.Six] = "6",
	[Enum.KeyCode.Seven] = "7",
	[Enum.KeyCode.Eight] = "8",
	[Enum.KeyCode.Nine] = "9",
	[Enum.KeyCode.KeypadZero] = "0",
	[Enum.KeyCode.KeypadOne] = "1",
	[Enum.KeyCode.KeypadTwo] = "2",
	[Enum.KeyCode.KeypadThree] = "3",
	[Enum.KeyCode.KeypadFour] = "4",
	[Enum.KeyCode.KeypadFive] = "5",
	[Enum.KeyCode.KeypadSix] = "6",
	[Enum.KeyCode.KeypadSeven] = "7",
	[Enum.KeyCode.KeypadEight] = "8",
	[Enum.KeyCode.KeypadNine] = "9",
}

-- One authored digit box. The authored colours are read once at bind time so
-- the rejection flash has something true to return to -- reading them back off
-- the instance mid-flash would return the flash's own colour.
type Slot = {
	frame: GuiObject,
	label: TextLabel,
	background: Color3,
	stroke: UIStroke?,
	strokeColor: Color3,
	flash: Motion.Handle?,
}

-- Everything the attach loop found, or nil if it has not found it yet. One
-- record rather than a scatter of optional locals: each function nil-checks
-- once and then has the whole panel.
type Panel = {
	root: GuiObject,
	keypad: GuiObject,
	closeButton: GuiButton,
	hintLabel: TextLabel,
	slots: { Slot },
	-- Where gamepad selection lands on open. nil if the pad authored no digits.
	firstKey: GuiButton?,
}

local TypeModeController = {}

local panel: Panel? = nil
local panelOpen = false

-- The digits so far, "" through "0047".
local typed = ""

-- os.clock() floor on the next submit. See submit().
local nextSubmitAt = 0

-- HUD.Root.MobileControls.TypeButton and the container that holds it.
-- Optional: a keyboard player is entirely served without either.
local typeButton: GuiButton? = nil
local mobileControls: GuiObject? = nil

-- Said once, not once per respawn: the attach loop re-finds the touch button
-- after every PlayerGui wipe, and a HUD that never authored it would otherwise
-- warn every time the player dies.
local touchButtonWarned = false

--[[
	One bounded WaitForChild per path segment.

	PlayerGui is populated by replication from StarterGui, so a direct index
	here is a race that passes on a fast machine. Returns nil rather than
	logging: the caller knows which element it asked for and can name it.
]]
local function findElement(root: Instance, path: { string }): Instance?
	local current: Instance = root
	for _, name in path do
		local child = current:WaitForChild(name, ELEMENT_TIMEOUT)
		if child == nil then
			return nil
		end
		current = child
	end
	return current
end

local function stale(path: string, class: string)
	log.warn(`Screens.{SCREEN_NAME}.{path} is missing or is not a {class} -- the panel cannot open. Re-author it.`)
end

--[[
	A focused TextBox owns the keyboard. ContextActionService is meant to stay
	quiet while one has focus, and this guard makes "typing 't' in the chat bar
	opened the keypad" impossible rather than merely unlikely -- the failure it
	prevents is silent, constant and in the player's face.
]]
local function keyboardIsClaimed(): boolean
	return UserInputService:GetFocusedTextBox() ~= nil
end

local function render()
	local current = panel
	if current == nil then
		return
	end
	for index, slot in current.slots do
		-- string.sub past the end returns "", so an untyped box empties itself
		-- with no branch. The authored box is its own placeholder.
		slot.label.Text = string.sub(typed, index, index)
	end
end

local function setTyped(value: string)
	typed = value
	render()
end

--[[
	Back to the authored colours, now. A cancelled Motion tween stops where it
	stands rather than snapping to its goal, so the restore has to be written by
	hand -- otherwise a close mid-flash leaves the boxes pink until the next
	rejection.
]]
local function restoreSlots()
	local current = panel
	if current == nil then
		return
	end
	for _, slot in current.slots do
		if slot.flash ~= nil then
			slot.flash.cancel()
			slot.flash = nil
		end
		slot.frame.BackgroundColor3 = slot.background
		if slot.stroke ~= nil then
			slot.stroke.Color = slot.strokeColor
		end
	end
end

local function flashRejection()
	local current = panel
	if current == nil then
		return
	end

	for _, slot in current.slots do
		if slot.flash ~= nil then
			-- Two rejections in a row are two flashes, not a queue: the second
			-- one restarts from full red rather than waiting for the first.
			slot.flash.cancel()
		end

		local stroke = slot.stroke

		--[[
			Motion.value hands the caller `from` synchronously, so the boxes are
			red on this frame and eased back over a quarter second. One proxy
			drives the fill and the stroke together, so they cannot fall out of
			step, and it is a fade OUT -- there is never a moment where the
			animation owes the player something before they can type again.
		]]
		slot.flash = Motion.value(1, 0, "smooth", function(alpha)
			slot.frame.BackgroundColor3 = slot.background:Lerp(REJECT_COLOR, alpha)
			if stroke ~= nil then
				stroke.Color = slot.strokeColor:Lerp(REJECT_COLOR, alpha)
			end
		end, function()
			slot.flash = nil
		end)
	end
end

--[[
	Sends the full code. Only appendDigit calls this, on the digit that
	completes the code, so every code is sent exactly once.
]]
local function submit()
	if panel == nil then
		return
	end

	--[[
		Config.RateLimit.CodeSubmit is the server's own floor on this packet: a
		second submit inside it is dropped there, and the client would then show
		a rejection for a code nobody judged. A clock reading rather than a
		task.delay handle -- there is no timer to cancel on close, and no state
		to be stuck in if a reply never arrives.

		Throttled, the digits are cleared rather than left up. Nothing can
		resend a full code (see confirm), so four boxes left full would be a
		code that looks sent, was never sent, and cannot be sent.
	]]
	local now = os.clock()
	if now < nextSubmitAt then
		setTyped("")
		flashRejection()
		return
	end
	nextSubmitAt = now + Config.RateLimit.CodeSubmit

	Net.submitCode.send({ code = typed })

	-- The digits stay up until the answer lands. The player should see what
	-- they sent, and codeResult clears them on either outcome.
end

local function appendDigit(digit: string)
	if #typed >= Config.Code.Digits then
		-- The boxes are full and that code is already on its way. A shake here
		-- would read as a rejection the server has not sent yet.
		return
	end
	typed ..= digit
	render()

	-- The last digit sends the code. A code is only ever exactly
	-- Config.Code.Digits long, so no Enter press is needed to mark the end
	-- of one.
	if #typed == Config.Code.Digits then
		submit()
	end
end

local function deleteDigit()
	if #typed == 0 then
		return
	end
	setTyped(string.sub(typed, 1, #typed - 1))
end

--[[
	Enter and the keypad's OK. They no longer send anything: a full code went
	out on its last digit. Resending it here would get a second reply to the
	same miss, and that reply lands after the first one has already cleared the
	boxes, so it wipes the next code the player has started typing.

	They stay bound for the short case. A player who presses Enter on two
	digits still gets told this is not a code, rather than nothing happening.
]]
local function confirm()
	if panel == nil then
		return
	end

	if #typed < Config.Code.Digits then
		--[[
			A short code can only come back BadCode, and the trip would spend
			the rate-limit window the next real submit needs. Same red as a
			server rejection, because it is the same answer -- arriving sooner.
		]]
		flashRejection()
	end
end

local function open()
	if panel == nil then
		return
	end

	--[[
		Typing only means anything while you are in the round and alive.
		Opening from the menu or the killcam would offer an input whose every
		answer is NotPlaying, and would put a keypad over the killcam's card.
		The server refuses those submits regardless; this is so the player is
		never invited to make one.
	]]
	local phase = MatchController.getPhase()
	if phase ~= "Playing" then
		log.debug(`ignored: phase is {phase}, not Playing`)
		return
	end

	UIController.open(SCREEN_NAME)
end

local function toggle()
	if UIController.isOpen(SCREEN_NAME) then
		UIController.close(SCREEN_NAME)
	else
		open()
	end
end

local function onKeyPressed(value: string)
	if value == CLEAR_VALUE then
		setTyped("")
		restoreSlots()
	elseif value == SUBMIT_VALUE then
		confirm()
	else
		appendDigit(value)
	end
end

local function onTypedInput(_action: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	if keyboardIsClaimed() then
		return Enum.ContextActionResult.Pass
	end

	if state ~= Enum.UserInputState.Begin then
		-- Sink the release too: these keys are ours for the whole press while
		-- the panel is up, and half a press reaching ToolbarController is worse
		-- than none of it.
		return Enum.ContextActionResult.Sink
	end

	local keyCode = input.KeyCode
	local digit = DIGIT_KEYS[keyCode]

	if digit ~= nil then
		appendDigit(digit)
	elseif keyCode == Binds.BACKSPACE.keyboard or keyCode == Binds.BACKSPACE.gamepad then
		deleteDigit()
	elseif keyCode == Binds.CONFIRM.keyboard or keyCode == Enum.KeyCode.KeypadEnter then
		-- KeypadEnter is the numpad twin of Binds.CONFIRM, not a second binding:
		-- a player typing digits on the pad expects the Enter under their hand.
		confirm()
	end

	return Enum.ContextActionResult.Sink
end

local function onToggleInput(_action: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin or keyboardIsClaimed() then
		return Enum.ContextActionResult.Pass
	end
	toggle()
	return Enum.ContextActionResult.Sink
end

-- A bind table is allowed to have no entry for a device (Binds.THROW is a mouse
-- button), and a nil in the list handed to table.unpack would truncate it.
local function addKey(keys: { any }, key: any)
	if key ~= nil then
		table.insert(keys, key)
	end
end

local function bindInput()
	-- `{ any }`: this goes straight into a variadic engine call, and Binds'
	-- per-device fields are optional by shape.
	local keys: { any } = {}
	for keyCode in DIGIT_KEYS do
		addKey(keys, keyCode)
	end
	addKey(keys, Binds.BACKSPACE.keyboard)
	addKey(keys, Binds.BACKSPACE.gamepad)
	addKey(keys, Binds.CONFIRM.keyboard)
	addKey(keys, Enum.KeyCode.KeypadEnter)

	--[[
		Binds.CANCEL is deliberately absent too. The panel closes on the key
		that opened it (TOGGLE_ACTION), so one key both opens and closes it and
		the player never has to learn a second one. Leaving Escape unbound also
		gives it back to the Roblox menu, which a sunk Escape was blocking for
		as long as the panel stayed open.
	]]

	--[[
		Binds.CONFIRM.gamepad (ButtonA) is deliberately absent. A is the
		engine's own "activate the selected GuiButton", and selection IS the
		gamepad's route into this panel -- a pad has no number row, so the
		keypad is the input, not a convenience. Sinking A would leave a gamepad
		player unable to press any key on the pad they have to use. Nothing is
		lost: the last digit sends the code, whichever device typed it.
	]]
	ContextActionService:BindActionAtPriority(INPUT_ACTION, onTypedInput, false, INPUT_PRIORITY, table.unpack(keys))
end

local function unbindInput()
	-- Harmless if nothing is bound, which is what makes it safe to call from
	-- the close path no matter how the close was reached.
	ContextActionService:UnbindAction(INPUT_ACTION)
end

--[[
	Gamepad selection, pointed at the pad while we own the screen.

	Only ever cleared if the selection is still inside our screen: another
	screen may have taken it in the meantime, and stealing it back to nil would
	leave that screen unusable.
]]
local function updateSelection()
	local current = panel
	if current == nil then
		return
	end

	if panelOpen and Device.isGamepad() then
		if current.firstKey ~= nil and GuiService.SelectedObject == nil then
			GuiService.SelectedObject = current.firstKey
		end
		return
	end

	-- The whole root, not just the keypad: CloseButton is a selectable button
	-- that sits OUTSIDE Keypad on purpose, so a selection parked on it would
	-- survive the close and leave the pad pointing at a hidden control.
	local selected = GuiService.SelectedObject
	if selected ~= nil and selected:IsDescendantOf(current.root) then
		GuiService.SelectedObject = nil
	end
end

local function hintText(): string
	local device = Device.get()
	-- No submit step in any of these: the last digit sends the code. Closing
	-- names the key that opened the panel, since that is the only one that
	-- closes it.
	if device == "Touch" then
		return `TAP {Config.Code.Digits} DIGITS`
	end
	if device == "Gamepad" then
		return `{Binds.label(Binds.BACKSPACE)} DELETE / {Binds.label(Binds.TYPE_MODE)} CLOSE`
	end
	return `TYPE {Config.Code.Digits} DIGITS / {Binds.label(Binds.TYPE_MODE)} CLOSE`
end

local function applyDevice()
	local current = panel
	if current ~= nil then
		--[[
			The on-screen pad is for the devices that have no other way in. On
			desktop it is slower than the number row the player's hands are
			already on, and the first-person camera has the mouse locked to the
			centre anyway, so it would not even be clickable.
		]]
		local pointerDriven = Device.get() ~= "Desktop"
		current.keypad.Visible = pointerDriven
		current.closeButton.Visible = pointerDriven
		current.hintLabel.Text = hintText()
		updateSelection()
	end

	--[[
		The touch button and the container it sits in. Every owner of a
		MobileControls button writes the container from the same Device answer,
		so whoever runs last agrees with whoever ran first -- and each of them
		owns only its own button's Visible, which is the part that is actually
		this controller's to decide.
	]]
	local touch = Device.isTouch()
	if typeButton ~= nil then
		typeButton.Visible = touch
	end
	if mobileControls ~= nil then
		mobileControls.Visible = touch
	end
end

local function onScreenOpened()
	panelOpen = true
	-- Every open starts blank. Digits left from the last one are a code the
	-- player did not choose to send now.
	setTyped("")
	restoreSlots()
	bindInput()

	--[[
		Deferred, alone among these. UIController fires onOpen BEFORE it sets
		ScreenGui.Enabled -- it poses the root first so the screen never renders
		a frame at its authored position -- and the engine will not hold a
		selection on a GuiObject inside a disabled ScreenGui. Selecting here and
		now would be dropped, and a gamepad player, whose only route into this
		panel IS the on-screen keypad, would find it up with nothing
		highlighted and no way to reach it.
	]]
	task.defer(updateSelection)
end

local function onScreenClosed()
	panelOpen = false
	unbindInput()
	setTyped("")
	restoreSlots()
	updateSelection()
end

--[[
	Keys are addressed by their KeyValue attribute, never by parsing "Key7" out
	of a name: the attribute is the promise the authored button makes, and it
	survives a designer renaming or reordering the pad.
]]
local function keyValueOf(button: GuiButton): string?
	local raw = button:GetAttribute(KEY_VALUE_ATTRIBUTE)

	local value: string
	if type(raw) == "string" then
		value = raw
	elseif type(raw) == "number" then
		-- Authored with the number picker rather than the string one. What it
		-- meant is unambiguous, so take it rather than killing the key.
		value = tostring(math.floor(raw))
	else
		log.warn(`{button:GetFullName()} has no usable {KEY_VALUE_ATTRIBUTE} ({typeof(raw)}) -- that key does nothing`)
		return nil
	end

	if value ~= CLEAR_VALUE and value ~= SUBMIT_VALUE and string.match(value, "^%d$") == nil then
		log.warn(
			`{button:GetFullName()}.{KEY_VALUE_ATTRIBUTE} is "{value}" -- expected one digit, {CLEAR_VALUE} or {SUBMIT_VALUE}`
		)
		return nil
	end

	return value
end

--[[
	Wires every keypad button and reports where gamepad selection should land.
	Connections live as long as the buttons do; a PlayerGui wipe destroys both
	together.
]]
local function bindKeypad(keypad: GuiObject): GuiButton?
	local firstKey: GuiButton? = nil
	local wired = 0

	for _, child in keypad:GetChildren() do
		if not child:IsA("GuiButton") then
			continue
		end

		local value = keyValueOf(child)
		if value == nil then
			continue
		end

		-- Narrowed into a plain local before the closure captures it: a
		-- refinement does not survive the boundary.
		local pressed: string = value
		local button = child

		if firstKey == nil and string.match(pressed, "^%d$") ~= nil then
			firstKey = button
		end

		button.Activated:Connect(function()
			onKeyPressed(pressed)
		end)
		wired += 1
	end

	if wired == 0 then
		log.warn(
			`Screens.{SCREEN_NAME}.Root.Keypad has no buttons carrying a {KEY_VALUE_ATTRIBUTE} attribute -- touch and gamepad players cannot type`
		)
	end

	return firstKey
end

--[[
	Forgets the bound panel and releases everything that outlives it.

	A wipe is not a close: a destroyed screen never fires one, so the input
	binds would outlive the panel and keep the number row sunk for a player
	with nothing left to type into. Called before the loop below waits for the
	replacement, so nothing afterwards writes into a destroyed tree -- and
	those writes do NOT error, they just stop being visible.
]]
local function clearPanel()
	if panelOpen then
		onScreenClosed()
	end

	panel = nil
	typeButton = nil
	mobileControls = nil
end

--[[
	Finds every element of one TypeMode screen and takes ownership of it.

	False, with the missing path already named, if the screen is not the
	authored one. The caller stops rather than retrying: the copy re-cloned on
	the next respawn is the same authored tree, so retrying would only repeat
	the same warning for the rest of the session.
]]
local function bindPanel(screen: Instance): boolean
	local root = findElement(screen, { "Root" })
	if root == nil or not root:IsA("GuiObject") then
		stale("Root", "GuiObject")
		return false
	end

	local digits = findElement(root, { "Panel", "Digits" })
	if digits == nil then
		stale("Root.Panel.Digits", "GuiObject")
		return false
	end

	--[[
		Config.Code.Digits drives the loop, not the number of children: the
		panel authors four boxes because Config says four. If the two ever
		disagree, the missing box is named here rather than the player typing
		digits that land nowhere visible.
	]]
	local slots: { Slot } = {}
	for index = 1, Config.Code.Digits do
		local frame = findElement(digits, { `Digit{index}` })
		if frame == nil or not frame:IsA("GuiObject") then
			stale(`Root.Panel.Digits.Digit{index}`, "GuiObject")
			return false
		end

		local label = findElement(frame, { "TextLabel" })
		if label == nil or not label:IsA("TextLabel") then
			stale(`Root.Panel.Digits.Digit{index}.TextLabel`, "TextLabel")
			return false
		end

		local stroke = frame:FindFirstChildOfClass("UIStroke")
		table.insert(slots, {
			frame = frame,
			label = label,
			background = frame.BackgroundColor3,
			stroke = stroke,
			strokeColor = if stroke ~= nil then stroke.Color else Color3.new(),
			flash = nil,
		})
	end

	local keypad = findElement(root, { "Keypad" })
	if keypad == nil or not keypad:IsA("GuiObject") then
		stale("Root.Keypad", "GuiObject")
		return false
	end

	local closeButton = findElement(root, { "CloseButton" })
	if closeButton == nil or not closeButton:IsA("GuiButton") then
		stale("Root.CloseButton", "GuiButton")
		return false
	end

	local hintLabel = findElement(root, { "HintLabel" })
	if hintLabel == nil or not hintLabel:IsA("TextLabel") then
		stale("Root.HintLabel", "TextLabel")
		return false
	end

	panel = {
		root = root,
		keypad = keypad,
		closeButton = closeButton,
		hintLabel = hintLabel,
		slots = slots,
		firstKey = bindKeypad(keypad),
	}

	-- Connected per bind rather than per session: this is a new instance after
	-- every re-clone, and the connection dies with the one it was made on.
	closeButton.Activated:Connect(function()
		UIController.close(SCREEN_NAME)
	end)

	return true
end

--[[
	The HUD's touch button. It lives in another screen but dies in the same
	wipe, so it is re-found on the same pass rather than on a watcher of its
	own -- two threads waiting on one respawn is one more than the problem has.
]]
local function bindTouchButton(screens: Instance)
	local function missing(what: string)
		if touchButtonWarned then
			return
		end
		touchButtonWarned = true
		log.warn(`{what} -- touch players cannot type`)
	end

	local controls = findElement(screens, { HUD_SCREEN_NAME, "Root", "MobileControls" })
	if controls == nil or not controls:IsA("GuiObject") then
		missing(`Screens.{HUD_SCREEN_NAME}.Root.MobileControls is missing`)
		return
	end

	mobileControls = controls

	local button = findElement(controls, { "TypeButton" })
	if button == nil or not button:IsA("GuiButton") then
		missing(`Screens.{HUD_SCREEN_NAME}.Root.MobileControls has no TypeButton`)
		return
	end

	typeButton = button
	button.Activated:Connect(toggle)
end

--[[
	Finds the panel, drives it, and re-finds it for the rest of the session.

	The loop is not defensive padding. StarterGui.ResetPlayerGuiOnSpawn is on
	by default and wipes PlayerGui on EVERY respawn -- and in this game a
	player respawns every few seconds -- so the panel bound at join is a
	destroyed instance from the first death onwards. Binding once would leave
	typing, which is the entire game, silently dead from the player's first
	death, with no error anywhere to find it by. UIController re-registers the
	replacement screen for exactly the same reason.

	Destroying:Wait() rather than a connection: there is no handle to forget to
	disconnect, and this thread has nothing else to do in the meantime.
]]
local function attachLoop()
	local playerGui = player:WaitForChild("PlayerGui")

	while true do
		-- WaitForChild, not a direct index: PlayerGui is populated by
		-- replication from StarterGui, so the screens are reliably absent for
		-- the first frames even when they HAVE been authored.
		local screens = playerGui:WaitForChild(SCREENS_FOLDER, SCREEN_TIMEOUT)
		if screens == nil then
			log.info(`no PlayerGui.{SCREENS_FOLDER} folder -- nothing to drive`)
			return
		end

		local screen = screens:WaitForChild(SCREEN_NAME, SCREEN_TIMEOUT)
		if screen == nil then
			log.info(`no {SCREENS_FOLDER}.{SCREEN_NAME} authored yet -- typing is unavailable`)
			return
		end

		if not bindPanel(screen) then
			-- bindPanel named what is missing, and the next re-clone carries
			-- the same authored tree.
			return
		end

		bindTouchButton(screens)
		setTyped("")

		-- UIController registers the screen off the same ChildAdded that
		-- resumed the WaitForChild above, and two handlers of one signal
		-- resume in no defined order. A frame later the registration has
		-- definitely landed, so the close below addresses a screen that exists
		-- rather than logging that it does not (MenuCameraController.syncLoop
		-- waits here for the same reason).
		task.wait()

		--[[
			Whatever the screen was left Enabled as in Studio, the panel is not
			part of the spawn: the player has to ask for it. This is also what
			keeps panelOpen honest -- UIController registers an authored-open
			screen with open = true without ever firing onOpen, so a panel that
			shipped Enabled would otherwise sit on screen with no binds behind
			it.
		]]
		UIController.close(SCREEN_NAME)
		applyDevice()

		screen.Destroying:Wait()
		clearPanel()

		--[[
			Destroying fires while the screen is still parented, so rescanning
			on that same resumption can be handed back the very copy on its way
			out -- and this thread would then park on a corpse's Destroying for
			the rest of the session, which is precisely the failure the loop
			exists to prevent.
		]]
		repeat
			task.wait()
		until screen.Parent == nil
	end
end

function TypeModeController.Init()
	--[[
		In Init, not Start: a codeResult can land while Start is still waiting
		on PlayerGui, and a packet fired at a client with no listener yet is
		dropped rather than queued (Net.luau says the same about devAccess).
	]]
	Net.codeResult.listen(function(data)
		if not panelOpen then
			-- The answer to a code sent just before the panel closed -- a kill
			-- that landed, a respawn. HUDController still draws it; there is
			-- nothing left here to clear.
			return
		end

		if data.accepted then
			--[[
				The code is spent and the elimination banner belongs to
				HUDController. Closing hands the number row, the mouse and the
				toolbar back to a player who has stopped typing -- holding the
				panel open would keep ToolbarController's throw suppressed for
				someone who is now just standing there.
			]]
			UIController.close(SCREEN_NAME)
			return
		end

		--[[
			A miss costs the digits and nothing else: no lockout, no disabled
			state, nothing to sit through. The red lands on the boxes rather
			than the text because the text is already gone. HUDController turns
			`reason` into words; this end only has to make the panel ready for
			the next attempt, which it already is by the time the flash starts.
		]]
		setTyped("")
		flashRejection()
	end)
end

function TypeModeController.Start()
	--[[
		Bind and unbind off the SCREEN's own open/close, not off our own two
		entry points. Anything that closes this panel -- a phase change, the
		close button, another controller -- then releases the keys, and there is
		exactly one place that can forget to.

		Registered once, out here rather than inside attachLoop, for the reason
		HUDController.Start gives: a rebind after a respawn must not stack a
		second listener on every path. They fire into `panel`, which is nil
		until a pass binds one, and every function below nil-checks it.
	]]
	UIController.onOpen(SCREEN_NAME, onScreenOpened)
	UIController.onClose(SCREEN_NAME, onScreenClosed)

	MatchController.onPhaseChanged(function(phase)
		if phase ~= "Playing" and UIController.isOpen(SCREEN_NAME) then
			-- Dying with the panel up would leave a keypad over the killcam,
			-- holding digits that are no longer anyone's to send.
			UIController.close(SCREEN_NAME)
		end
	end)

	--[[
		The toggle stays bound for the session -- it is how the panel is asked
		for, so there is no "closed" state in which T should do nothing, and no
		PlayerGui wipe that should take it away.

		createTouchButton is false on purpose: ContextActionService's generated
		button is a second, unauthored control floating over a HUD that already
		authors TypeButton for exactly this.
	]]
	local toggleKeys: { any } = {}
	addKey(toggleKeys, Binds.TYPE_MODE.keyboard)
	addKey(toggleKeys, Binds.TYPE_MODE.gamepad)
	ContextActionService:BindActionAtPriority(
		TOGGLE_ACTION,
		onToggleInput,
		false,
		TOGGLE_PRIORITY,
		table.unpack(toggleKeys)
	)

	-- A device is what someone is USING, and that changes mid-session: a player
	-- who picks up a controller needs the pad to appear without reopening.
	Device.onChanged(applyDevice)

	-- Parks for the session. The Loader spawns every Start(), so nothing is
	-- waiting on this one to return.
	attachLoop()
end

return TypeModeController
