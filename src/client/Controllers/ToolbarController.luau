--!strict
--[[
	The toolbar: two slots, which one is live, and the three things a slot can
	do -- select, throw, drop.

	THE SERVER OWNS THE SLOTS; THIS DRAWS THEM

	Every value on screen here arrived in Net.loadout, which LoadoutService
	pushes on spawn and after every change. The client never adds, removes or
	counts an item, so it has no copy of the toolbar to get wrong. Selection is
	the one thing that starts on this side, and even that is a request: the
	highlight moves the instant the key is pressed so the input feels
	connected, and the server's next push overwrites whatever this thought.
	When the two disagree, the server's answer is the one left standing.

	THROW DIRECTION IS THE CAMERA'S, NOT THE CHARACTER'S

	throwItem carries a direction because the server genuinely cannot compute
	one -- it holds the character's facing, and the player is aiming with the
	camera (Net.luau, `throwItem`). That is the one fact only this machine has,
	which is also why sending it concedes nothing: the server normalises it,
	sanity-checks it, and owns the grenade from there.

	INPUT IS DEAD UNLESS THE PLAYER IS PLAYING AND NOT TYPING

	  - Phase. The actions are bound when the phase becomes Playing and unbound
	    when it leaves, so the menu, team select and the killcam cannot reach
	    the toolbar at all, rather than reaching it and being ignored.
	  - TypeMode. Someone halfway through a four-digit code is typing, not
	    aiming, and the click that lands on the keypad must not also throw a
	    grenade. Asked live through UIController.isOpen rather than mirrored
	    into a flag here, because TypeMode closes for reasons this controller
	    never hears about -- a death, a round ending.

	THROWING IS CHARGED

	Pressing the throw input with something in hand starts a charge; releasing
	throws it. How long it was held, over Config.Throw.ChargeTime, is the
	`charge` the packet carries (0 = a quick tap, 1 = a full second), and the
	server turns it into the launch speed. While charging, HUD.Root.ChargeBar
	beside the crosshair fills -- shown only after Config.Throw.BarDelay, so a
	quick tap never flashes it. A charge is dropped, not thrown, if anything
	takes the hand away first: a slot change, the item going, the phase ending,
	or TypeMode opening.

	THE HUD IS RE-FOUND ON EVERY RESPAWN

	StarterGui.ResetPlayerGuiOnSpawn wipes and re-clones PlayerGui when the
	character spawns (UIController.luau, Init), and in this game dying is the
	loop. The elements found at boot are destroyed instances a minute later, so
	bindHud drops its connections and runs again against the replacement
	instead of drawing into a screen nobody is looking at.
]]

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Binds = require(script.Parent.Parent.UI.Binds)
local CameraController = require(script.Parent.CameraController)
local Config = require(ReplicatedStorage.Shared.Config)
local Device = require(script.Parent.Parent.UI.Device)
local Items = require(ReplicatedStorage.Shared.Items)
local Log = require(ReplicatedStorage.Shared.Log)
local Match = require(ReplicatedStorage.Shared.Match)
local MatchController = require(script.Parent.MatchController)
local Motion = require(script.Parent.Parent.UI.Motion)
local Net = require(ReplicatedStorage.Shared.Net)
local UIController = require(script.Parent.UIController)

local log = Log.new("ToolbarController")

local player = Players.LocalPlayer

local SLOT_COUNT = Config.Toolbar.SlotCount

-- Bounded, like HUDController's: a missing screen must surface as one warning
-- rather than a Start() that never finishes.
local SCREEN_TIMEOUT = 10

-- Namespaced so no other controller's UnbindAction can reach ours by accident.
local ACTION_SELECT = "ToolbarSelect"
local ACTION_THROW = "ToolbarThrow"
local ACTION_DROP = "ToolbarDrop"

-- Selection carries two signals, not one: the stroke goes fully opaque and the
-- slot grows slightly. A colour change alone is the signal a colour-blind
-- player is least likely to read -- the same argument Match.TEAMS makes for
-- spelling out RED and BLUE next to the team colour.
local SELECTED_SCALE = 1.06
local UNSELECTED_SCALE = 1
local SELECTED_STROKE_TRANSPARENCY = 0
local UNSELECTED_STROKE_TRANSPARENCY = 0.55

-- Buttons.luau owns the UIScale of anything tagged this, for hover and press.
local BUTTON_TAG = "UIButton"

type SlotView = {
	shortLabel: TextLabel?,
	keyLabel: TextLabel?,
	emptyLabel: GuiObject?,
	stroke: UIStroke?,
	-- nil when the slot carries the UIButton tag: Buttons.luau already drives
	-- that button's own UIScale, and two owners writing one property is a
	-- fight neither wins. The stroke then carries selection on its own.
	scale: UIScale?,
	-- The stroke colour as authored, captured before anything overwrites it,
	-- so an empty slot returns to what the designer drew rather than to a
	-- constant invented in this file.
	authoredStrokeColor: Color3,
	handle: Motion.Handle?,
}

-- The last loadout the server pushed. Always exactly SLOT_COUNT long with ""
-- for empty (Net.luau, `loadout`), so nothing here reasons about holes.
local slotItems: { string } = {}
local selectedSlot = 1

local slotViews: { SlotView } = {}
local mobileControls: GuiObject? = nil
local throwButton: GuiButton? = nil
local dropButton: GuiButton? = nil

-- HUD.Root.ChargeBar and its Fill, on the current HUD copy. Optional: without
-- them a charge still works, it just is not drawn.
local chargeBar: GuiObject? = nil
local chargeFill: GuiObject? = nil
-- os.clock() the current charge began, or nil when not charging.
local chargeStartedAt: number? = nil
-- The touch that started a charge on the ThrowButton; its end is the release.
local chargeTouch: InputObject? = nil
local chargeConnection: RBXScriptConnection? = nil
-- Forward declared: selection (above the charging section) drops a charge.
local cancelCharge: () -> ()

-- Everything bound to the CURRENT PlayerGui copy of the HUD, dropped as a
-- batch when that copy is replaced. Destroying the screen would disconnect
-- these anyway; keeping the list means a rebind is also a clean one.
local guiConnections: { RBXScriptConnection } = {}

-- Bumped by every bind. A HUD that arrives while an older bind is still waiting
-- on its frames has to win, or the toolbar ends up wired to the copy the player
-- cannot see -- two respawns in quick succession is all it takes.
local bindGeneration = 0
local toolbarBound = false

local inputBound = false

-- os.clock() of the last packet of each kind. A tap on the mobile ThrowButton
-- that also arrives as a click, or a trigger held past its threshold twice,
-- would otherwise spend the server's rate-limit budget on one intent -- and the
-- next throw, the one the player did mean, is the one that gets dropped.
-- Mirrors Config.RateLimit.ItemAction, which is the floor the server enforces.
local lastSentAt: { [string]: number } = {}

-- Keyed by item id so a loadout pushed every few seconds cannot fill the output
-- with the same complaint.
local reportedUnknownItems: { [string]: boolean } = {}

local ToolbarController = {}

--[[
	FindFirstChild, not WaitForChild. bindHud waits for the Toolbar itself, and
	a slot's own labels arrive in the same batch as the frame that owns them; a
	label still missing at that point is an authoring mistake, and the answer to
	an authoring mistake is one warning naming it, not a thread that sits out a
	timeout per element and leaves the rest of the toolbar undrawn.
]]
local function findLabel(parent: Instance, name: string): TextLabel?
	local instance = parent:FindFirstChild(name)
	if instance == nil then
		log.warn(`{parent:GetFullName()} has no {name} -- that part of the slot will not draw`)
		return nil
	end
	if not instance:IsA("TextLabel") then
		log.warn(`{instance:GetFullName()} should be a TextLabel, got {instance.ClassName} -- not drawn`)
		return nil
	end
	return instance
end

local function findButton(parent: Instance, name: string): GuiButton?
	local instance = parent:FindFirstChild(name)
	if instance == nil then
		log.warn(`{parent:GetFullName()} has no {name} -- that control will not work`)
		return nil
	end
	if not instance:IsA("GuiButton") then
		log.warn(`{instance:GetFullName()} should be a button, got {instance.ClassName} -- not wired`)
		return nil
	end
	return instance
end

local function allowSend(kind: string): boolean
	local now = os.clock()
	local previous = lastSentAt[kind]
	if previous ~= nil and now - previous < Config.RateLimit.ItemAction then
		return false
	end
	lastSentAt[kind] = now
	return true
end

local function inputAllowed(): boolean
	if UIController.isOpen("TypeMode") then
		return false
	end
	-- Re-checked even though the actions are only bound while Playing: the
	-- mobile buttons and the slot taps are plain GUI connections that live for
	-- as long as the screen does, and they have no bind to be unbound.
	return MatchController.getPhase() == "Playing"
end

--[[
	Binds names exactly the two slots Config.Toolbar.SlotCount has today. A
	third slot needs a name there before it can have a key here, which is the
	point of the file: no controller invents a key of its own.
]]
local function slotForKeyCode(keyCode: Enum.KeyCode): number?
	if keyCode == Binds.SLOT_1.keyboard or keyCode == Binds.SLOT_1.gamepad then
		return 1
	elseif keyCode == Binds.SLOT_2.keyboard or keyCode == Binds.SLOT_2.gamepad then
		return 2
	end
	return nil
end

-- The prompt text for the CURRENT device ("1", "D-PAD LEFT"), or nil for a slot
-- no bind names.
local function slotKeyLabel(index: number): string?
	if index == 1 then
		return Binds.label(Binds.SLOT_1)
	elseif index == 2 then
		return Binds.label(Binds.SLOT_2)
	end
	return nil
end

local function drawSlot(index: number, view: SlotView)
	local itemId = slotItems[index] or ""
	local definition = Items.byId(itemId)

	if itemId ~= "" and definition == nil and not reportedUnknownItems[itemId] then
		reportedUnknownItems[itemId] = true
		-- The server put something in the slot that this client's catalog does
		-- not know. Drawing it as empty is the honest fallback; saying so is
		-- how anyone finds out the two sides shipped different Items.luau.
		log.warn(`slot {index} holds "{itemId}", which is not in Items -- drawing it as empty`)
	end

	-- EmptyLabel rather than a blank ShortLabel: a slot has to read as
	-- "nothing here", not as a label that failed to load.
	local emptyLabel = view.emptyLabel
	if emptyLabel ~= nil then
		emptyLabel.Visible = definition == nil
	end

	local shortLabel = view.shortLabel
	if shortLabel ~= nil then
		shortLabel.Text = if definition ~= nil then definition.ShortName else ""
		shortLabel.Visible = definition ~= nil
	end

	local selected = index == selectedSlot

	local stroke = view.stroke
	if stroke ~= nil then
		stroke.Color = if definition ~= nil then definition.Color else view.authoredStrokeColor
		-- Snapped, not tweened. A highlight that fades in reads as lag on the
		-- key that was just pressed; only the scale is allowed to take time.
		stroke.Transparency = if selected then SELECTED_STROKE_TRANSPARENCY else UNSELECTED_STROKE_TRANSPARENCY
	end

	local scale = view.scale
	local targetScale = if selected then SELECTED_SCALE else UNSELECTED_SCALE
	-- Only when it actually has to move. A loadout push is a redraw of every
	-- slot, and starting a tween to the scale a slot is already at would churn
	-- a NumberValue and a connection per push for no visible change.
	if scale ~= nil and scale.Scale ~= targetScale then
		if view.handle ~= nil then
			-- Cancel rather than let it land: a fast 1-2-1 should read as one
			-- continuous movement, not three that queue up.
			view.handle.cancel()
			view.handle = nil
		end
		view.handle = Motion.tween(scale, { Scale = targetScale }, "snappy", function()
			view.handle = nil
		end)
	end
end

local function redraw()
	for index, view in slotViews do
		drawSlot(index, view)
	end

	--[[
		The first-person arm follows the selected slot, not the inventory.

		Here rather than in setSelectedSlot because BOTH things that can empty
		the hand run through this function: changing slot, and the loadout
		packet that lands after a throw takes the grenade away. Wiring only the
		first would leave the arm on screen holding nothing every time a player
		threw something, which is the exact moment they are looking at it.

		Compared against "" rather than counted: an empty slot is the empty
		string by contract (Net.luau, loadout) precisely so this kind of check
		never has to reason about holes.
	]]
	CameraController.setHoldingItem((slotItems[selectedSlot] or "") ~= "")
end

local function refreshKeyLabels()
	for index, view in slotViews do
		local keyLabel = view.keyLabel
		if keyLabel == nil then
			continue
		end
		local label = slotKeyLabel(index)
		keyLabel.Text = label or ""
		--[[
			Binds.label answers for the CURRENT device, so this reads "1" on a
			desktop, "D-PAD L" on a gamepad and "TAP" on a phone -- which is
			true there, because the slot itself is the button. The hide is for
			the slot no bind names at all (slotKeyLabel returns nil past slot
			2), where an empty label would otherwise sit in the layout looking
			like a label that failed to load.
		]]
		keyLabel.Visible = label ~= nil and label ~= ""
	end
end

local function refreshDevice()
	local touch = Device.isTouch()

	local throw = throwButton
	if throw ~= nil then
		throw.Visible = touch
	end

	local drop = dropButton
	if drop ~= nil then
		drop.Visible = touch
	end

	--[[
		Shown from here, never hidden. MobileControls also holds TypeButton and
		SprintButton, whose owners may have their own reason to want the
		container up; the two buttons above carry the decision that is actually
		this controller's.
	]]
	local controls = mobileControls
	if touch and controls ~= nil then
		controls.Visible = true
	end

	refreshKeyLabels()
end

local function setSelectedSlot(slot: number)
	if slot == selectedSlot then
		-- LoadoutService ignores a re-select, so this would be a packet nobody
		-- reads and a rate-limit slot nobody gets back.
		return
	end

	selectedSlot = slot
	-- A charge belongs to the item that was in hand when it began.
	cancelCharge()
	redraw()

	--[[
		Not gated by allowSend: throwItem and dropItem carry the slot index
		explicitly, so a selectSlot the server's limiter drops costs nothing but
		the server's record of which slot is highlighted -- never a throw that
		comes out of the wrong slot.
	]]
	Net.selectSlot.send({ slot = slot })
end

-- Both return whether a packet actually went out, which is what decides
-- between sinking the input and passing it on.
local function throwSelected(charge: number): boolean
	if not inputAllowed() then
		return false
	end

	local camera = workspace.CurrentCamera
	if camera == nil then
		return false
	end

	--[[
		No "is the slot empty?" check here on purpose. The server consumes the
		item and holds the only copy that counts; a stale empty on this side
		would eat a throw the player really could make, while a throw from a
		genuinely empty slot costs one packet the server drops before it spends
		anything (GrenadeService.onThrow).
	]]
	local direction = camera.CFrame.LookVector

	-- A NaN vector is not equal to itself, and that is the only test that
	-- catches it (quality-gate.md trap #8). Cheap insurance against sending a
	-- direction the server can only reject.
	if direction ~= direction then
		return false
	end

	-- Last, not first. The gate exists to stop ONE intent spending two of the
	-- server's rate-limit slots; a throw that never leaves this function is not
	-- an intent the server ever saw, and burning the gate on it would drop the
	-- real throw 200ms later.
	if not allowSend("throw") then
		return false
	end

	Net.throwItem.send({ slot = selectedSlot, direction = direction, charge = charge })
	return true
end

--========================================================================
-- CHARGING
--========================================================================

-- A charge can run only while a throw could: playing, not typing, and with
-- something in the selected slot.
local function canCharge(): boolean
	return inputAllowed() and (slotItems[selectedSlot] or "") ~= ""
end

local function chargeLevel(startedAt: number): number
	return math.clamp((os.clock() - startedAt) / Config.Throw.ChargeTime, 0, 1)
end

local function hideChargeBar()
	local bar = chargeBar
	if bar ~= nil then
		bar.Visible = false
	end
end

function cancelCharge()
	chargeStartedAt = nil
	chargeTouch = nil
	local connection = chargeConnection
	chargeConnection = nil
	if connection ~= nil then
		connection:Disconnect()
	end
	hideChargeBar()
end

-- Draws the bar every frame of a charge, and drops the charge the moment the
-- hand can no longer throw.
local function drawCharge()
	local startedAt = chargeStartedAt
	if startedAt == nil then
		return
	end
	if not canCharge() then
		cancelCharge()
		return
	end
	local bar, fill = chargeBar, chargeFill
	if bar == nil or fill == nil then
		return
	end
	bar.Visible = os.clock() - startedAt >= Config.Throw.BarDelay
	-- Fills from the bottom: the Fill is anchored at its bottom edge in Studio.
	fill.Size = UDim2.fromScale(1, chargeLevel(startedAt))
end

local function beginCharge(): boolean
	if chargeStartedAt ~= nil or not canCharge() then
		return false
	end
	chargeStartedAt = os.clock()
	chargeConnection = RunService.RenderStepped:Connect(drawCharge)
	return true
end

-- Throws with however much was charged. False if there was no charge to
-- release or the throw did not go out.
local function releaseCharge(): boolean
	local startedAt = chargeStartedAt
	if startedAt == nil then
		return false
	end
	local charge = chargeLevel(startedAt)
	cancelCharge()
	return throwSelected(charge)
end

local function dropSelected(): boolean
	if not inputAllowed() or not allowSend("drop") then
		return false
	end

	Net.dropItem.send({ slot = selectedSlot })
	return true
end

--[[
	Sink only what was acted on. An input this controller ignored -- because the
	player is typing, or because it is not a slot key -- has to keep travelling,
	or binding the toolbar quietly swallows inputs belonging to whoever bound
	them first.
]]
local function onSelectAction(
	_actionName: string,
	state: Enum.UserInputState,
	input: InputObject
): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end

	local slot = slotForKeyCode(input.KeyCode)
	if slot == nil or not inputAllowed() then
		return Enum.ContextActionResult.Pass
	end

	setSelectedSlot(slot)
	return Enum.ContextActionResult.Sink
end

-- Press starts the charge, release throws it. A cancelled input (focus lost
-- mid-hold) drops the charge rather than throwing.
local function onThrowAction(
	_actionName: string,
	state: Enum.UserInputState,
	_input: InputObject
): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		return if beginCharge() then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
	elseif state == Enum.UserInputState.End then
		return if releaseCharge() then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
	elseif state == Enum.UserInputState.Cancel then
		cancelCharge()
	end
	return Enum.ContextActionResult.Pass
end

local function onDropAction(
	_actionName: string,
	state: Enum.UserInputState,
	_input: InputObject
): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	return if dropSelected() then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
end

--[[
	Drops the nils before BindAction sees them.

	Binds may type its fields as optional -- a bind that has no gamepad key is a
	legal bind -- and BindAction takes keys, not maybes. select("#", ...) rather
	than `#`, because the whole point is that the arguments may contain nils and
	the length of such a table is undefined in Luau (quality-gate.md trap #9).
]]
local function collectKeys(...: (Enum.KeyCode | Enum.UserInputType)?): { Enum.KeyCode | Enum.UserInputType }
	local keys: { Enum.KeyCode | Enum.UserInputType } = {}
	for index = 1, select("#", ...) do
		local key = select(index, ...)
		if key ~= nil then
			table.insert(keys, key)
		end
	end
	return keys
end

local function bindActions()
	if inputBound then
		return
	end
	inputBound = true

	-- createTouchButton is false everywhere: the touch controls are authored in
	-- the HUD (MobileControls), and ContextActionService's own buttons would
	-- float a second, unstyled set on top of them.
	local selectKeys =
		collectKeys(Binds.SLOT_1.keyboard, Binds.SLOT_1.gamepad, Binds.SLOT_2.keyboard, Binds.SLOT_2.gamepad)
	ContextActionService:BindAction(ACTION_SELECT, onSelectAction, false, table.unpack(selectKeys))

	local throwKeys = collectKeys(Binds.THROW.mouse, Binds.THROW.gamepad)
	ContextActionService:BindAction(ACTION_THROW, onThrowAction, false, table.unpack(throwKeys))

	--[[
		DROP's gamepad key is ButtonX, which BACKSPACE also uses inside
		TypeMode. That is not a collision: TypeMode binds its own action when it
		opens, and the most recently bound action is the one ContextActionService
		asks first -- and inputAllowed() refuses here regardless.
	]]
	local dropKeys = collectKeys(Binds.DROP.keyboard, Binds.DROP.gamepad)
	ContextActionService:BindAction(ACTION_DROP, onDropAction, false, table.unpack(dropKeys))
end

local function unbindActions()
	if not inputBound then
		return
	end
	inputBound = false

	ContextActionService:UnbindAction(ACTION_SELECT)
	ContextActionService:UnbindAction(ACTION_THROW)
	ContextActionService:UnbindAction(ACTION_DROP)
end

local function applyPhase(phase: Match.PlayerPhase)
	if phase == "Playing" then
		bindActions()
	else
		-- Unbinding means the release never arrives; the charge goes now.
		cancelCharge()
		unbindActions()
	end
end

local function clearGuiBindings()
	for _, connection in guiConnections do
		connection:Disconnect()
	end
	table.clear(guiConnections)

	for _, view in slotViews do
		if view.handle ~= nil then
			view.handle.cancel()
			view.handle = nil
		end
	end
	table.clear(slotViews)

	-- Nilled, not left pointing at the destroyed copy: refreshDevice runs on
	-- device changes that have nothing to do with the screen, and writing
	-- Visible on a destroyed instance is a silent no-op that hides the bug.
	mobileControls = nil
	throwButton = nil
	dropButton = nil
	chargeBar = nil
	chargeFill = nil
	cancelCharge()
end

-- HUD.Root.ChargeBar with a Fill inside. Optional, like everything drawn here.
local function bindChargeBar(root: Instance)
	local bar = root:FindFirstChild("ChargeBar")
	local fill = if bar ~= nil then bar:FindFirstChild("Fill") else nil
	if bar == nil or not bar:IsA("GuiObject") or fill == nil or not fill:IsA("GuiObject") then
		log.warn("HUD.Root has no ChargeBar.Fill -- throws still charge, but the bar will not draw")
		return
	end
	bar.Visible = false
	chargeBar = bar
	chargeFill = fill
end

local function bindSlot(index: number, frame: GuiObject)
	local stroke = frame:FindFirstChildOfClass("UIStroke")
	if stroke == nil then
		log.warn(`{frame:GetFullName()} has no UIStroke -- the item colour and the selection have nothing to draw on`)
	end

	local scale: UIScale? = nil
	if CollectionService:HasTag(frame, BUTTON_TAG) then
		-- Buttons.luau finds or creates this slot's UIScale for hover and
		-- press. Selection stays off it rather than fighting over one property:
		-- the stroke says which slot is live either way.
		log.debug(`{frame.Name} is tagged {BUTTON_TAG}; selection will not scale it`)
	else
		-- Its OWN UIScale, found or made. Not a GUI tree: a UIScale is a
		-- modifier on an authored frame, the same one Buttons.luau adds to a
		-- tagged button.
		local ownScale = frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
		ownScale.Parent = frame
		scale = ownScale
	end

	local emptyLabel = frame:FindFirstChild("EmptyLabel")

	local view: SlotView = {
		shortLabel = findLabel(frame, "ShortLabel"),
		keyLabel = findLabel(frame, "KeyLabel"),
		emptyLabel = if emptyLabel ~= nil and emptyLabel:IsA("GuiObject") then emptyLabel else nil,
		stroke = stroke,
		scale = scale,
		authoredStrokeColor = if stroke ~= nil then stroke.Color else Color3.new(1, 1, 1),
		handle = nil,
	}
	slotViews[index] = view

	-- Tapping a slot selects it (touch), and clicking one does the same thing
	-- for the same reason -- a slot that looks pressable and is not reads as
	-- broken. A Frame gets InputBegan instead, so the layout is free to be
	-- either.
	if frame:IsA("GuiButton") then
		table.insert(
			guiConnections,
			frame.Activated:Connect(function()
				if inputAllowed() then
					setSelectedSlot(index)
				end
			end)
		)
	else
		table.insert(
			guiConnections,
			frame.InputBegan:Connect(function(input: InputObject)
				local isTap = input.UserInputType == Enum.UserInputType.Touch
					or input.UserInputType == Enum.UserInputType.MouseButton1
				if isTap and inputAllowed() then
					setSelectedSlot(index)
				end
			end)
		)
	end
end

--[[
	ThrowButton and DropButton, taken off Root rather than off the Toolbar.

	On a phone these two buttons are the ENTIRE input scheme for this
	controller -- there is no key to fall back to -- so they are wired before
	the Toolbar is even looked for. Nesting them inside the toolbar's success
	path is how "the toolbar will not draw, but throwing still works" becomes a
	promise the code does not keep: the slots and the touch buttons are
	independent halves of the screen, and one missing must not take the other
	down with it.
]]
local function bindMobileControls(root: Instance)
	local controls = root:FindFirstChild("MobileControls")
	if controls == nil or not controls:IsA("GuiObject") then
		log.warn("HUD.Root has no MobileControls -- a touch player will have nothing to throw or drop with")
		return
	end

	local throw = findButton(controls, "ThrowButton")
	local drop = findButton(controls, "DropButton")

	mobileControls = controls
	throwButton = throw
	dropButton = drop

	if throw ~= nil then
		-- Touch down starts the charge; the same touch ending -- wherever the
		-- finger is by then -- throws it (see the InputEnded hook in Start).
		table.insert(
			guiConnections,
			throw.InputBegan:Connect(function(input: InputObject)
				local isPress = input.UserInputType == Enum.UserInputType.Touch
					or input.UserInputType == Enum.UserInputType.MouseButton1
				if isPress and beginCharge() then
					chargeTouch = input
				end
			end)
		)
	end
	if drop ~= nil then
		table.insert(
			guiConnections,
			drop.Activated:Connect(function()
				dropSelected()
			end)
		)
	end
end

local function bindHud(hud: ScreenGui)
	bindGeneration += 1
	local generation = bindGeneration

	clearGuiBindings()

	--[[
		WaitForChild, bounded, and not a plain index: a ScreenGui is parented
		into PlayerGui before the last of its descendants has replicated, so its
		frames are reliably absent for the first frames even when they HAVE been
		authored -- a direct index is a race that happens to pass on a fast
		machine (HUDController.luau makes the same point about the screen
		itself). Bounded, so a HUD with no Toolbar is one warning rather than a
		thread that waits forever.

		The generation is re-checked after EVERY wait, not once at the end: each
		one is a place a newer HUD can arrive, and everything past a stale check
		writes state belonging to a screen that is already destroyed.
	]]
	local root = hud:WaitForChild("Root", SCREEN_TIMEOUT)
	if generation ~= bindGeneration then
		-- A newer HUD arrived while this one was waiting. That bind owns the
		-- state now, and everything below would overwrite it with frames from a
		-- screen that is already gone.
		return
	end

	if root == nil then
		log.warn("HUD has no Root -- nothing on this screen can be driven")
		return
	end

	bindMobileControls(root)
	bindChargeBar(root)

	local toolbar = root:WaitForChild("Toolbar", SCREEN_TIMEOUT)
	if generation ~= bindGeneration then
		return
	end

	if toolbar == nil then
		log.warn("HUD.Root has no Toolbar -- the slots will not draw. Throwing and dropping still work.")
		-- The touch buttons bound above still need their visibility decided,
		-- or a phone is left with an input scheme that is wired but invisible.
		refreshDevice()
		return
	end

	for index = 1, SLOT_COUNT do
		local frame = toolbar:FindFirstChild(`Slot{index}`)
		if frame == nil or not frame:IsA("GuiObject") then
			log.warn(`HUD.Root.Toolbar has no Slot{index} frame -- that slot will not draw`)
			continue
		end
		bindSlot(index, frame)
	end
	toolbarBound = true

	refreshDevice()
	-- The loadout that arrived before this screen existed is drawn now. That is
	-- the whole reason the packet listener lives in Init and the lookup does
	-- not: the first push lands on spawn, which beats PlayerGui more often than
	-- not, and every push after it is a change the player caused.
	redraw()
end

--[[
	Every HUD, now and after every respawn.

	Spawned rather than called: DescendantAdded must not yield and bindHud
	waits on the screen's own frames. A filter this cheap on a signal this
	chatty is the trade UIController.Init makes too -- PlayerGui churns wholesale
	and scanning it once is how a controller ends up driving a destroyed screen.
]]
local function considerScreen(instance: Instance)
	if instance.Name ~= "HUD" or not instance:IsA("ScreenGui") then
		return
	end

	--[[
		Refuse anything outside the folder UIController adopted. The engine's
		spawn-time copy announces a second, valid-looking HUD through
		DescendantAdded just before UIController destroys it, and a controller
		that binds to that one writes into a destroyed tree for the rest of the
		session without erroring (UIController.getScreensFolder).
	]]
	local folder = UIController.getScreensFolder()
	if folder == nil or not instance:IsDescendantOf(folder) then
		return
	end

	local hud = instance
	task.spawn(function()
		bindHud(hud)
	end)
end

function ToolbarController.Init()
	--[[
		Init, not Start. LoadoutService pushes the loadout from CharacterAdded,
		and a packet that arrives before this listener exists is dropped, not
		queued -- the player would then hold two grenades the toolbar draws as
		empty until something else changed.

		The draw is safe this early: slotViews is empty until bindHud runs, so
		redraw() is a no-op loop rather than an index into a screen that does
		not exist yet.
	]]
	Net.loadout.listen(function(data)
		slotItems = data.slots
		selectedSlot = data.selected
		redraw()
	end)
end

function ToolbarController.Start()
	--[[
		Input is wired before the screen is looked up, and does not depend on
		it. The toolbar DRAWS the loadout, it does not own it: a place whose HUD
		is only half authored should still be able to throw, and a warning is a
		better answer than a controller that silently binds nothing.
	]]
	MatchController.onPhaseChanged(function(phase)
		applyPhase(phase)
	end)

	-- onPhaseChanged fires on changes only. Nothing can have changed yet --
	-- Main.client.luau calls Replica.RequestData() after every Start has been
	-- spawned -- but reading the phase once costs nothing and removes the
	-- assumption from the ordering.
	applyPhase(MatchController.getPhase())

	Device.onChanged(function()
		refreshDevice()
	end)

	-- The end of the touch that started a charge on the ThrowButton. Global
	-- rather than on the button: a thumb that drifts off the button while
	-- charging must still throw when it lifts.
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if chargeTouch ~= nil and input == chargeTouch then
			releaseCharge()
		end
	end)

	local playerGui = player:WaitForChild("PlayerGui")

	--[[
		Watched, not scanned once. PlayerGui is empty this early -- StarterGui is
		copied in when the character spawns, well after Start -- and
		StarterGui.ResetPlayerGuiOnSpawn wipes and re-clones the whole of it on
		every respawn (UIController.luau, Init). In a game whose loop is dying,
		the HUD found at boot is a destroyed instance a minute later, and a
		controller that only scanned would draw into it forever.

		DescendantAdded rather than ChildAdded because screens may be organised
		into subfolders of Screens, so the HUD is not necessarily a child of
		anything this code can name.
	]]
	playerGui.DescendantAdded:Connect(considerScreen)

	-- And the one that is already there: in Studio the first character can spawn
	-- before this line runs.
	local existing = playerGui:FindFirstChild("HUD", true)
	if existing ~= nil then
		considerScreen(existing)
	end

	--[[
		Diagnostics only. A place with no HUD authored yet should say so once
		rather than sit silent, and saying it on a delay -- instead of erroring,
		or waiting inline -- leaves the watcher above free to pick one up if it
		is added later in the session.
	]]
	task.delay(SCREEN_TIMEOUT, function()
		if not toolbarBound then
			log.warn("no HUD.Root.Toolbar found -- nothing to draw. Input is bound; throwing still works.")
		end
	end)
end

return ToolbarController
