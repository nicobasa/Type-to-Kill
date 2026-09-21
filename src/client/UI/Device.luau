--!strict
--[[
	Which input device the player is using RIGHT NOW.

	Not what is plugged in -- what was last touched. Those are different
	questions, and the static capability flags only answer the first:

		UserInputService.TouchEnabled      true on a Windows laptop with a
		                                   touchscreen, whether or not anyone
		                                   has ever touched it
		UserInputService.KeyboardEnabled   true on that same laptop

	So a HUD that shows thumb buttons because TouchEnabled is true ships them
	to every touchscreen laptop, and one that hides them because
	KeyboardEnabled is true hides them on that laptop from a player who is
	actually tapping. Neither flag is wrong; the machine genuinely has both,
	and no combination of them can pick. The last input CAN -- and it
	re-answers mid-session, for free, when the player switches.

	A plain module, no lifecycle (ARCHITECTURE.md Recipe 3). Require it
	directly and read it in two lines:

		local Device = require(script.Parent.Parent.UI.Device)

		applyDevice(Device.get())        -- what they are using now
		Device.onChanged(applyDevice)    -- and every time that changes
]]

local UserInputService = game:GetService("UserInputService")

export type Kind = "Desktop" | "Touch" | "Gamepad"

--[[
	The mapping IS the policy, and what is left OUT of it matters more than
	what is in it.

	Focus (alt-tab), TextInput (the on-screen keyboard while chatting), Gyro,
	Accelerometer and None all arrive through LastInputTypeChanged like
	everything else, and none of them says what the player is holding. A phone
	player who opens the chat bar raises TextInput; map that anywhere and the
	touch controls vanish off their HUD mid-sentence. An input type absent from
	this table therefore leaves the current device alone rather than defaulting.

	All eight gamepad slots land on the same answer -- Roblox reports which pad
	(Gamepad1..Gamepad8), never a generic "a gamepad".
]]
local DEVICE_BY_INPUT: { [Enum.UserInputType]: Kind } = {
	[Enum.UserInputType.Touch] = "Touch",

	[Enum.UserInputType.Keyboard] = "Desktop",
	[Enum.UserInputType.MouseButton1] = "Desktop",
	[Enum.UserInputType.MouseButton2] = "Desktop",
	[Enum.UserInputType.MouseButton3] = "Desktop",
	[Enum.UserInputType.MouseWheel] = "Desktop",
	[Enum.UserInputType.MouseMovement] = "Desktop",

	[Enum.UserInputType.Gamepad1] = "Gamepad",
	[Enum.UserInputType.Gamepad2] = "Gamepad",
	[Enum.UserInputType.Gamepad3] = "Gamepad",
	[Enum.UserInputType.Gamepad4] = "Gamepad",
	[Enum.UserInputType.Gamepad5] = "Gamepad",
	[Enum.UserInputType.Gamepad6] = "Gamepad",
	[Enum.UserInputType.Gamepad7] = "Gamepad",
	[Enum.UserInputType.Gamepad8] = "Gamepad",
}

local listeners: { (device: Kind) -> () } = {}

--[[
	The answer before anyone has pressed anything.

	GetLastInputType() is None (or Focus) for a player who has only just
	joined, so the first seconds of the HUD have nothing but the capability
	flags to go on and the ambiguity above is unavoidable. It resolves toward
	the keyboard on purpose: a touchscreen laptop is a desktop until someone
	taps it, and that first tap corrects this through LastInputTypeChanged
	anyway. Guessing Touch instead would flash thumb buttons at every laptop
	player on join.
]]
local function resolveInitial(): Kind
	-- Annotated optional, here and in the handler below: a `{ [K]: Kind }` read
	-- is typed Kind, not Kind?, so the nil test would be rejected -- and an
	-- unannotated local loses the singleton union, widening the result to a
	-- plain string that no longer satisfies Kind.
	local fromLastInput: Kind? = DEVICE_BY_INPUT[UserInputService:GetLastInputType()]
	if fromLastInput ~= nil then
		return fromLastInput
	end

	if UserInputService.KeyboardEnabled then
		return "Desktop"
	end
	if UserInputService.TouchEnabled then
		return "Touch"
	end
	if UserInputService.GamepadEnabled then
		return "Gamepad"
	end
	return "Desktop"
end

local current: Kind = resolveInitial()

--[[
	Connected at require time rather than from an Init(), which is safe because
	nothing here yields: a controller that requires this module from its own
	Init() pays one table lookup and one connection. The gain is that there is
	no window in which the module is loaded but not listening, so the very
	first switch -- which on console happens before the player has seen a
	single frame -- is already covered.
]]
UserInputService.LastInputTypeChanged:Connect(function(inputType: Enum.UserInputType)
	local device: Kind? = DEVICE_BY_INPUT[inputType]
	if device == nil or device == current then
		return
	end

	current = device

	for _, listener in listeners do
		-- Spawned per listener, for the same reason UIController fires its
		-- screen listeners this way: one controller erroring while it redraws
		-- its prompts must not stop the rest of the UI hearing about the
		-- switch, and a listener that yields must not stall the signal.
		task.spawn(listener, device)
	end
end)

local Device = {}

function Device.get(): Kind
	return current
end

--[[
	Fires when the player switches device, and NOT with the current one.

	Deliberately unlike DataController.observe, which replays because its value
	honestly is not available yet when you subscribe. This one always is:
	Device.get() answers synchronously on the first line of Start(), so a
	replay could only ever be a second call carrying what the caller just read.
	The two-line idiom at the top of this file is the whole story.

	Listeners are held for the session and there is no unsubscribe -- the same
	trade UIController.onOpen makes, and fine for controllers, which are
	singletons. Subscribe from module or Start scope only. One registered per
	character or per round is a leak that grows all session.
]]
function Device.onChanged(listener: (device: Kind) -> ())
	table.insert(listeners, listener)
end

--[[
	"Is the player tapping right now", NOT "does this machine have a
	touchscreen" -- see the header for why those differ. If you ever need the
	capability instead, read UserInputService.TouchEnabled directly and say in
	a comment why the capability is the right question there.
]]
function Device.isTouch(): boolean
	return current == "Touch"
end

function Device.isGamepad(): boolean
	return current == "Gamepad"
end

return Device
