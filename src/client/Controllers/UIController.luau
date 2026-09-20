--!strict
--[[
	The one place that decides which screen is on screen.

		UIController.open("Shop")     -- closes whatever else was open. That IS the swap.
		UIController.close("Shop")
		UIController.toggle("Shop")

	Studio owns the GUIs (see ARCHITECTURE.md), so this is deliberately not a
	registry you populate from code. Put a ScreenGui under StarterGui.Screens and
	it is a screen, addressed by its name -- nothing to register, nothing to keep
	in sync with a tree you edit in another program. Same trade the Loader makes
	with its Service/Controller suffix, for the same reason.

	Authored in Studio, read here:

		Screens/                    (Folder -- subfolders are yours to organise
		  Shop                       with; they do not affect the name)
		    Enabled     the starting state. What you leave visible in Studio is
		                what the player spawns into.
		    Transition  "Scale" (default) | "Fade" | "SlideUp" | "SlideDown"
		                | "SlideLeft" | "SlideRight" | "None"
		    Exclusive   default true. false for a HUD or a toast: it stacks
		                instead of taking the screen.
		    <one root GuiObject>    the thing that actually moves

	Buttons are opt-in through the `UIButton` tag -- see UI/Buttons.luau.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Buttons = require(script.Parent.Parent.UI.Buttons)
local Log = require(ReplicatedStorage.Shared.Log)
local Motion = require(script.Parent.Parent.UI.Motion)
local Transitions = require(script.Parent.Parent.UI.Transitions)

local log = Log.new("UIController")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local SCREENS_FOLDER = "Screens"

type Screen = {
	name: string,
	gui: ScreenGui,
	root: GuiObject,
	transition: Transitions.Name,
	exclusive: boolean,
	open: boolean,
	-- 0 shown, 1 hidden. Kept so an interrupted transition resumes from where it
	-- actually is instead of snapping to an end first.
	alpha: number,
	handle: Motion.Handle?,
}

type Listeners = { [string]: { (name: string) -> () } }

local screens: { [string]: Screen } = {}
local openListeners: Listeners = {}
local closeListeners: Listeners = {}

local UIController = {}

local function fire(listeners: Listeners, name: string)
	local list = listeners[name]
	if list == nil then
		return
	end
	for _, listener in list do
		-- Spawned: a listener that yields or errors must not strand a
		-- transition half-applied.
		task.spawn(listener, name)
	end
end

local function subscribe(listeners: Listeners, name: string, listener: (name: string) -> ())
	local list = listeners[name]
	if list == nil then
		list = {}
		listeners[name] = list
	end
	table.insert(list, listener)
end

local function show(screen: Screen)
	if screen.open then
		return
	end
	screen.open = true

	if screen.handle ~= nil then
		screen.handle.cancel()
		screen.handle = nil
	end

	fire(openListeners, screen.name)

	if screen.transition == "None" then
		screen.alpha = 0
		screen.gui.Enabled = true
		return
	end

	local pose = Transitions.begin(screen.root, screen.transition)

	-- Pose BEFORE enabling. Enable first and the screen renders one frame at its
	-- authored position, which reads as a flash rather than an entrance.
	pose(screen.alpha)
	screen.gui.Enabled = true

	screen.handle = Motion.value(screen.alpha, 0, "pop", function(alpha)
		screen.alpha = alpha
		pose(alpha)
	end, function()
		screen.handle = nil
	end)
end

local function hide(screen: Screen)
	if not screen.open then
		return
	end
	screen.open = false

	if screen.handle ~= nil then
		screen.handle.cancel()
		screen.handle = nil
	end

	fire(closeListeners, screen.name)

	if screen.transition == "None" then
		screen.alpha = 1
		screen.gui.Enabled = false
		return
	end

	local pose = Transitions.begin(screen.root, screen.transition)

	screen.handle = Motion.value(screen.alpha, 1, "snappy", function(alpha)
		screen.alpha = alpha
		pose(alpha)
	end, function()
		screen.handle = nil
		-- Reached only on a real finish -- Motion.value does not call back for a
		-- cancelled tween. That is what stops a close interrupted by a reopen
		-- from disabling the screen a frame after it came back.
		screen.gui.Enabled = false
	end)
end

--[[
	Opens a screen, closing any other exclusive one. Does not yield: the screen
	is "open" the moment you ask, the animation is just how it gets there.
]]
function UIController.open(name: string)
	local screen = screens[name]
	if screen == nil then
		log.warn(
			`open("{name}"): no such screen. Screens register when PlayerGui populates -- is it under StarterGui.{SCREENS_FOLDER}?`
		)
		return
	end

	if screen.exclusive then
		for _, other in screens do
			if other ~= screen and other.exclusive and other.open then
				-- Not sequenced: the outgoing screen leaves while the incoming
				-- one arrives. Waiting for the close would double the time the
				-- player spends looking at neither.
				hide(other)
			end
		end
	end

	show(screen)
end

function UIController.close(name: string)
	local screen = screens[name]
	if screen == nil then
		log.warn(`close("{name}"): no such screen`)
		return
	end
	hide(screen)
end

function UIController.toggle(name: string)
	local screen = screens[name]
	if screen == nil then
		log.warn(`toggle("{name}"): no such screen`)
		return
	end

	if screen.open then
		hide(screen)
	else
		UIController.open(name)
	end
end

function UIController.isOpen(name: string): boolean
	local screen = screens[name]
	return screen ~= nil and screen.open
end

--[[
	The open exclusive screen, if any -- the one Escape should close:

		local open = UIController.getOpen()
		if open ~= nil then
			UIController.close(open)
		end

	Only exclusive screens are reported, because only they can be asked "which
	one". A HUD and three toasts are all open at once; there is no answer there.
]]
function UIController.getOpen(): string?
	for name, screen in screens do
		if screen.exclusive and screen.open then
			return name
		end
	end
	return nil
end

--[[
	Fires when the screen starts opening, not when the animation ends -- you want
	the list populated as it arrives, not a quarter second after the player is
	already looking at it.
]]
function UIController.onOpen(name: string, listener: (name: string) -> ())
	subscribe(openListeners, name, listener)
end

function UIController.onClose(name: string, listener: (name: string) -> ())
	subscribe(closeListeners, name, listener)
end

local function booleanAttribute(gui: ScreenGui, name: string, default: boolean): boolean
	local value = gui:GetAttribute(name)
	if value == nil then
		return default
	end
	if type(value) ~= "boolean" then
		log.warn(`{gui.Name}.{name} should be a boolean, got {typeof(value)} -- using {default}`)
		return default
	end
	return value
end

local function register(gui: ScreenGui)
	local root: GuiObject? = nil
	local extra = 0

	for _, child in gui:GetChildren() do
		if child:IsA("GuiObject") then
			if root == nil then
				root = child
			else
				extra += 1
			end
		end
	end

	if root == nil then
		log.warn(`"{gui.Name}" has no GuiObject to animate -- put its content under a single root frame`)
		return
	end
	if extra > 0 then
		log.warn(
			`"{gui.Name}" has {extra + 1} top-level frames; only "{root.Name}" animates. Put the content under a single root frame.`
		)
	end

	local existing = screens[gui.Name]
	if existing ~= nil then
		if existing.gui.Parent ~= nil then
			log.warn(
				`two screens are named "{gui.Name}" -- the newer wins. Names address screens, so they must be unique.`
			)
		end
		-- Otherwise this is the respawn re-clone of one we already knew, and
		-- rebinding silently is exactly the point.
		if existing.handle ~= nil then
			existing.handle.cancel()
		end
		Transitions.forget(existing.root)
	end

	Transitions.prepare(root)

	local screen: Screen = {
		name = gui.Name,
		gui = gui,
		root = root,
		transition = Transitions.resolve(gui:GetAttribute("Transition")),
		exclusive = booleanAttribute(gui, "Exclusive", true),
		-- Enabled as authored IS the starting state, so Studio previews the
		-- spawn. No OpenOnStart attribute to set, and none to forget.
		open = gui.Enabled,
		alpha = if gui.Enabled then 0 else 1,
		handle = nil,
	}
	screens[gui.Name] = screen

	gui.Destroying:Connect(function()
		if screens[gui.Name] == screen then
			screens[gui.Name] = nil
		end
		Transitions.forget(screen.root)
	end)

	local stacking = if screen.exclusive then "exclusive" else "stacking"
	local starting = if screen.open then "open" else "closed"
	log.debug(`registered "{gui.Name}" ({screen.transition}, {stacking}, starts {starting})`)
end

local considerChild: (child: Instance) -> ()

local function watchContainer(container: Instance)
	for _, child in container:GetChildren() do
		considerChild(child)
	end
	container.ChildAdded:Connect(considerChild)
end

function considerChild(child: Instance)
	if child:IsA("ScreenGui") then
		register(child)
	elseif child:IsA("Folder") then
		-- Subfolders are organisation only. A screen is addressed by its own
		-- name, so Screens/Menus/Shop is still just "Shop".
		watchContainer(child)
	end
end

function UIController.Init()
	Buttons.start()

	local function considerRoot(child: Instance)
		if child.Name == SCREENS_FOLDER then
			watchContainer(child)
		end
	end

	--[[
		PlayerGui is empty this early: StarterGui is copied into it when the
		character spawns, which is well after every Init() has run. So this
		cannot scan and be done -- it has to watch.

		It also has to KEEP watching. StarterGui.ResetPlayerGuiOnSpawn (on by
		default) wipes and re-clones the whole of PlayerGui on every respawn, so
		the ScreenGui registered at spawn is a destroyed instance the moment the
		player first dies. register()'s Destroying handler drops it and this
		picks up the replacement -- and that churn is the reason screens are
		addressed by name rather than by handing out the instance.
	]]
	for _, child in playerGui:GetChildren() do
		considerRoot(child)
	end
	playerGui.ChildAdded:Connect(considerRoot)
end

function UIController.Start()
	if StarterGui:FindFirstChild(SCREENS_FOLDER) == nil then
		log.debug(
			`no StarterGui.{SCREENS_FOLDER} folder yet -- nothing to manage. ScreenGuis in one register themselves.`
		)
		return
	end

	if StarterGui.ResetPlayerGuiOnSpawn then
		--[[
			Not fatal -- screens rebind either way -- but every screen reverts to
			its authored Enabled state when the player dies, which reads to a
			player as "the menu closed itself". It defaults on because it
			predates PlayerGui being scriptable, not because it is what anyone
			wants.
		]]
		log.debug(
			"StarterGui.ResetPlayerGuiOnSpawn is on: screens reset to their authored state on every respawn. Turn it off unless you want that."
		)
	end
end

return UIController
