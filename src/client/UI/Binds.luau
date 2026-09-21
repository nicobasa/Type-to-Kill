--!strict
--[[
	Every bind in the game, named once.

	Two controllers each inventing their own key is how a game ends up with G
	dropping a grenade AND opening a menu, with neither author ever opening the
	other's file. Everything that reads input requires this module instead, so
	the whole control scheme fits on one screen and a collision is something
	you see while writing rather than in a playtest.

	WHAT IS NOT IN HERE: touch. The touch "bind" for every action below is an
	authored button under HUD.Root.MobileControls (TypeButton, SprintButton,
	ThrowButton, DropButton) -- an instance in the GUI tree, addressed by name,
	not a key this table could hold. Binds.label knows that and says TAP.

	ButtonY for TYPE_MODE is deliberate and collides with nothing: A is
	CONFIRM, B is CANCEL, X is DROP/BACKSPACE, L3 is SPRINT, R2 is THROW, and
	the D-Pad takes the two slots. Y is the only face button left free, and
	Type Mode is the headline action, so it gets it.

	THE ONE DELIBERATE DUPLICATE: ButtonX is both DROP and BACKSPACE. That is
	only safe because the two are never live at once -- TypeMode sinks its keys
	while it is open (Enum.ContextActionResult.Sink) and the toolbar does not
	act while TypeMode is open. Break either half and ButtonX starts throwing a
	grenade on the ground every time a gamepad player deletes a digit. A NEW
	duplicate needs that same argument written down beside it, or it is a bug.
]]

local Device = require(script.Parent.Device)

--[[
	Every field is optional and readers must test the one they want: THROW has
	no keyboard key at all (it is a mouse button), and nothing here has a touch
	key. Assuming all three are present is how a prompt ends up reading "nil".
]]
export type Bind = {
	keyboard: Enum.KeyCode?,
	gamepad: Enum.KeyCode?,
	mouse: Enum.UserInputType?,
}

-- Nothing to name on touch: the action IS a button, and the button carries
-- its own label.
local TOUCH_LABEL = "TAP"

-- Shown when a bind has no key for the current device. Visible and harmless,
-- rather than an empty string that reads as a layout bug.
local UNBOUND_LABEL = "--"

--[[
	Prompt text per key, spelled out rather than derived from EnumItem.Name,
	because those names are Roblox's and not the player's: Return, LeftShift,
	ButtonY and One have to read ENTER, SHIFT, Y and 1 on a prompt.

	A key missing from here falls back to its enum name, which looks wrong on
	screen on purpose -- a silently blank prompt is the version nobody notices.
]]
local KEY_LABELS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.T] = "T",
	[Enum.KeyCode.G] = "G",
	[Enum.KeyCode.One] = "1",
	[Enum.KeyCode.Two] = "2",
	[Enum.KeyCode.LeftShift] = "SHIFT",
	[Enum.KeyCode.Return] = "ENTER",
	[Enum.KeyCode.Escape] = "ESC",
	[Enum.KeyCode.Backspace] = "BKSP",

	[Enum.KeyCode.ButtonA] = "A",
	[Enum.KeyCode.ButtonB] = "B",
	[Enum.KeyCode.ButtonX] = "X",
	[Enum.KeyCode.ButtonY] = "Y",
	[Enum.KeyCode.ButtonL3] = "L3",
	[Enum.KeyCode.ButtonR2] = "R2",
	[Enum.KeyCode.DPadLeft] = "D-PAD L",
	[Enum.KeyCode.DPadRight] = "D-PAD R",
}

local MOUSE_LABELS: { [Enum.UserInputType]: string } = {
	[Enum.UserInputType.MouseButton1] = "CLICK",
}

local Binds = {}

--[[
	NOTE ON THE `::` CASTS -- do not "tidy" them into annotations. A type
	annotation is only legal on a local or a parameter, never on a
	table-property assignment (.claude/rules/quality-gate.md, Gate 2, trap #1).
	The cast is what makes every entry below the same Bind shape, so
	Binds.label accepts any of them.
]]
Binds.TYPE_MODE = { keyboard = Enum.KeyCode.T, gamepad = Enum.KeyCode.ButtonY } :: Bind
Binds.SPRINT = { keyboard = Enum.KeyCode.LeftShift, gamepad = Enum.KeyCode.ButtonL3 } :: Bind
Binds.SLOT_1 = { keyboard = Enum.KeyCode.One, gamepad = Enum.KeyCode.DPadLeft } :: Bind
Binds.SLOT_2 = { keyboard = Enum.KeyCode.Two, gamepad = Enum.KeyCode.DPadRight } :: Bind
Binds.THROW = { mouse = Enum.UserInputType.MouseButton1, gamepad = Enum.KeyCode.ButtonR2 } :: Bind
Binds.DROP = { keyboard = Enum.KeyCode.G, gamepad = Enum.KeyCode.ButtonX } :: Bind
Binds.CONFIRM = { keyboard = Enum.KeyCode.Return, gamepad = Enum.KeyCode.ButtonA } :: Bind
Binds.CANCEL = { keyboard = Enum.KeyCode.Escape, gamepad = Enum.KeyCode.ButtonB } :: Bind
Binds.BACKSPACE = { keyboard = Enum.KeyCode.Backspace, gamepad = Enum.KeyCode.ButtonX } :: Bind

local function keyLabel(key: Enum.KeyCode): string
	return KEY_LABELS[key] or string.upper(key.Name)
end

--[[
	The prompt text for the CURRENT device: "SHIFT" on desktop, "L3" on a
	gamepad, "TAP" on touch.

		hintLabel.Text = `HOLD {Binds.label(Binds.SPRINT)} TO SPRINT`

	Read it when you draw the prompt AND again from Device.onChanged. A player
	who puts the controller down and reaches for the keyboard must not be left
	reading "L3" -- that is the entire reason this takes the device from Device
	rather than a flag the caller passes in.
]]
function Binds.label(bind: Bind): string
	local device = Device.get()

	if device == "Touch" then
		return TOUCH_LABEL
	end

	if device == "Gamepad" then
		local gamepad = bind.gamepad
		return if gamepad ~= nil then keyLabel(gamepad) else UNBOUND_LABEL
	end

	-- Desktop. Keyboard first, mouse second: only THROW carries a mouse
	-- button, and nothing carries both, so the order is a preference that
	-- never actually has to choose.
	local keyboard = bind.keyboard
	if keyboard ~= nil then
		return keyLabel(keyboard)
	end

	local mouse = bind.mouse
	if mouse ~= nil then
		return MOUSE_LABELS[mouse] or string.upper(mouse.Name)
	end

	return UNBOUND_LABEL
end

return Binds
