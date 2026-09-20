--!strict
--[[
	Hover and press motion for tagged buttons.

	Opt-in by tag (`UIButton`), and that direction is deliberate. Plenty of
	buttons should NOT have this: a toggle that swaps its own image, a slider
	handle, a card that already animates, anything inside a list that scales as a
	group. An include tag makes those the default and costs one click in the
	Studio tag editor; an exclude tag would make silently-wrong motion the
	default and cost you finding out which button it was.

	Hover and press are held as two booleans and the scale is recomputed from
	them, rather than each event setting the scale it wants. That is not
	ceremony -- driving scale straight off events is the classic way to strand a
	button at 0.94: press it, drag the cursor off, release. MouseButton1Up never
	arrives, and nothing ever puts it back.

	Authored in Studio, read here (both optional, both live -- retag or retune
	while the game runs):

		HoverScale  number, default 1.05
		PressScale  number, default 0.94
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Log = require(ReplicatedStorage.Shared.Log)
local Motion = require(script.Parent.Motion)

local log = Log.new("Buttons")

local TAG = "UIButton"

local HOVER_SCALE = 1.05
local PRESS_SCALE = 0.94

type State = {
	uiScale: UIScale,
	connections: { RBXScriptConnection },
	hovered: boolean,
	pressed: boolean,
	handle: Motion.Handle?,
}

local bound: { [GuiButton]: State } = {}
local started = false

local Buttons = {}

local function numberAttribute(button: GuiButton, name: string, default: number): number
	local value = button:GetAttribute(name)
	if value == nil then
		return default
	end
	if type(value) ~= "number" then
		log.warn(`{button:GetFullName()}.{name} should be a number, got {typeof(value)} -- using {default}`)
		return default
	end
	return value
end

-- Read per frame of intent rather than cached at bind, so retuning a button in
-- Studio's property panel shows up on the next hover instead of the next
-- playtest.
local function targetScale(button: GuiButton, state: State): number
	if state.pressed then
		return numberAttribute(button, "PressScale", PRESS_SCALE)
	elseif state.hovered then
		return numberAttribute(button, "HoverScale", HOVER_SCALE)
	end
	return 1
end

local function refresh(button: GuiButton, state: State)
	if state.handle ~= nil then
		-- Cancel rather than let it finish: the new tween starts from wherever
		-- the old one got to, which is what makes a fast hover-out-hover-in
		-- read as one continuous movement.
		state.handle.cancel()
	end

	-- A press should feel like it lands under the finger, so it gets no
	-- overshoot. Everything else can afford the personality.
	local preset: Motion.Preset = if state.pressed then "snappy" else "pop"

	state.handle = Motion.tween(state.uiScale, { Scale = targetScale(button, state) }, preset, function()
		state.handle = nil
	end)
end

local function bind(instance: Instance)
	if not instance:IsA("GuiButton") then
		log.warn(`{instance:GetFullName()} is tagged {TAG} but is a {instance.ClassName} -- only buttons can hover`)
		return
	end

	if instance:IsDescendantOf(StarterGui) then
		-- The authored original, not the copy the player sees. It never renders
		-- and never fires an input event; its PlayerGui clone arrives tagged and
		-- gets bound on its own.
		return
	end

	if bound[instance] ~= nil then
		return
	end

	-- The button's OWN UIScale, never the screen root's. Nested UIScales
	-- multiply, so hover motion composes with the root's scale instead of
	-- overwriting it -- the root's UIScale belongs to Transitions during a
	-- "Scale" transition; a button writing it would fight over the same property.
	local uiScale = instance:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	uiScale.Parent = instance

	local state: State = {
		uiScale = uiScale,
		connections = {},
		hovered = false,
		pressed = false,
		handle = nil,
	}
	bound[instance] = state

	local button = instance

	local function set(hovered: boolean, pressed: boolean)
		if state.hovered == hovered and state.pressed == pressed then
			return
		end
		state.hovered = hovered
		state.pressed = pressed
		refresh(button, state)
	end

	table.insert(
		state.connections,
		button.MouseEnter:Connect(function()
			set(true, state.pressed)
		end)
	)

	table.insert(
		state.connections,
		button.MouseLeave:Connect(function()
			-- Clearing `pressed` here is the entire reason this is a state
			-- machine. Dragging off a held button never fires MouseButton1Up.
			set(false, false)
		end)
	)

	table.insert(
		state.connections,
		button.MouseButton1Down:Connect(function()
			set(state.hovered, true)
		end)
	)

	table.insert(
		state.connections,
		button.MouseButton1Up:Connect(function()
			set(state.hovered, false)
		end)
	)

	-- Gamepad focus is hover under another name.
	table.insert(
		state.connections,
		button.SelectionGained:Connect(function()
			set(true, state.pressed)
		end)
	)

	table.insert(
		state.connections,
		button.SelectionLost:Connect(function()
			set(false, false)
		end)
	)
end

local function unbind(instance: Instance)
	if not instance:IsA("GuiButton") then
		return
	end

	local state = bound[instance]
	if state == nil then
		return
	end
	bound[instance] = nil

	for _, connection in state.connections do
		connection:Disconnect()
	end
	if state.handle ~= nil then
		state.handle.cancel()
	end

	-- Untagging mid-hover would otherwise leave the button at 1.05 forever. A
	-- destroyed one has no parent and does not care either way.
	if state.uiScale.Parent ~= nil then
		state.uiScale.Scale = 1
	end
end

--[[
	Binds every tagged button, now and in future.

	Call once, from UIController.Init -- nothing here yields, and the removed
	signal covers both untagging and destruction, so a PlayerGui wipe on respawn
	cleans up and rebinds without a special case.
]]
function Buttons.start()
	if started then
		log.warn("start() called twice -- ignored")
		return
	end
	started = true

	CollectionService:GetInstanceAddedSignal(TAG):Connect(bind)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unbind)

	for _, instance in CollectionService:GetTagged(TAG) do
		bind(instance)
	end
end

return Buttons
