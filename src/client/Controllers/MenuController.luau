--!strict
--[[
	The screen router, and the main menu's own logic.

	Two questions decide everything here, and they are deliberately different
	questions:

	  WHERE IS THIS PLAYER?  MatchController.getPhase() -- Menu, TeamSelect,
	      Playing, Killcam. This picks which screen is up.
	  WHERE IS THE MATCH?    MatchController.getState() -- Lobby, Voting,
	      MapLoading, WaitingToPlay, RoundActive, RoundResults. This decides
	      whether PLAY is pressable and what the menu says about it.

	Keeping them apart is the entire reason Match.luau splits PlayerPhase from
	MatchState: someone who joins eight minutes into a live round sits in the
	Menu phase while the match sits in RoundActive, and a router reading one
	value would have to lie about the other.

	WHAT THIS CONTROLLER OWNS -- and, more usefully, what it must never touch:

	  Owns:  MainMenu, HUD, TeamSelect, plus the menu's own overlays
	         (Inventory, Shop, Settings), which only ever open from MainMenu.
	  Never: Vote, Results, Killcam. Those belong to VoteController,
	         ResultsController and KillcamController. All three are authored
	         NOT exclusive, so they stack over whatever is routed here and need
	         no cooperation from this file -- which is precisely why this file
	         closing one would be a bug you could not find from the screen it
	         broke.

	Studio owns the GUIs; code owns which one is on screen (UI-AND-MOTION.md).
	Nothing below builds a frame, a button or a label, and nothing below writes
	ScreenGui.Enabled -- that property belongs to UIController's transitions.

	There is no Init(): this controller listens to no packet and reads no
	replica directly. Everything it needs arrives through MatchController,
	whose own Init() registers the replica listener that cannot afford to be
	late. Its onPhaseChanged/onStateChanged prime a late subscriber with the
	current value, so registering them from Start() sees exactly what
	registering from Init() would have.

	Everything this file touches is a PlayerGui copy, and those do not survive a
	respawn -- see attachLoop, which is the reason this controller binds in a
	loop rather than once.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Match = require(ReplicatedStorage.Shared.Match)
local MatchController = require(script.Parent.MatchController)
local Motion = require(script.Parent.Parent.UI.Motion)
local Net = require(ReplicatedStorage.Shared.Net)
local UIController = require(script.Parent.UIController)

local log = Log.new("MenuController")

local player = Players.LocalPlayer

--[[
	ONE budget for finding everything this controller drives, not one per
	element. Bounded so an unauthored screen surfaces as a warning instead of a
	Start() that never returns, and shared so a missing screen costs ten
	seconds once rather than ten seconds per lookup.
]]
local BIND_TIMEOUT = 10

--[[
	How much of that budget a single hop must still have in hand before its
	timeout is allowed to PROVE the child is not there (see waitForPath).

	A hop handed the last fraction of a shared budget timed out because the
	budget ran out, not because the tree is missing anything, and remembering
	that as absence would permanently unbind an element that is authored and
	present. Under this window the lookup simply fails for the pass and is
	tried again on the next one.
]]
local ABSENCE_PROOF_WINDOW = 2

--[[
	The menu's countdown is a clock, not an animation. PhaseEndsAt is an
	ABSOLUTE timestamp (Match.luau), so nothing fires as the seconds tick past
	-- the label has to re-read the remaining time itself. Twice a second is
	enough for a whole-second readout and roughly 120x cheaper than doing it
	per frame.
]]
local STATUS_INTERVAL = 0.5

--[[
	How far PLAY recedes when it is not pressable, ADDED to whatever the button
	was authored with rather than assigned over it. The enabled look belongs to
	Studio; an absolute value here would quietly overrule the designer's own
	colours the first time they changed them, and nobody would connect the two.
]]
local DISABLED_BACKGROUND_FADE = 0.55
local DISABLED_TEXT_FADE = 0.45

local OWNED_SCREENS = { "MainMenu", "HUD", "TeamSelect" }

-- Reachable only from MainMenu, so leaving the Menu phase has to take them
-- with it. They are exclusive screens: one left open would sit on top of a
-- live round with no route back to the game.
local MENU_OVERLAYS = { "Inventory", "Shop", "Settings" }

-- Every overlay's close button sits at the same authored path, so there is one
-- constant rather than three that can drift apart.
local OVERLAY_CLOSE_PATH = { "Root", "Panel", "CloseButton" }

local PHASE_SCREEN: { [string]: string } = {
	Menu = "MainMenu",
	TeamSelect = "TeamSelect",
	Playing = "HUD",
	-- A dead player is still IN the round (Match.luau), so they keep the HUD
	-- and KillcamController stacks its own non-exclusive screen over it.
	Killcam = "HUD",
}

local MENU_BUTTONS = {
	{ path = { "Root", "Actions", "InventoryButton" }, screen = "Inventory" },
	{ path = { "Root", "Actions", "ShopButton" }, screen = "Shop" },
	{ path = { "Root", "SettingsButton" }, screen = "Settings" },
}

type StateDisplay = {
	--[[
		ONE string, drawn into both PlayButton.StatusLabel and
		MatchStatus.TextLabel. Two separately worded strings for the same fact
		drift the first time one of them is edited, and a menu that disagrees
		with itself about whether voting is open reads as broken.
	]]
	text: string,
	-- The contract, not a heuristic: PLAY is live in these two states only.
	playable: boolean,
	-- Whether a seconds countdown is worth appending. RoundActive is false on
	-- purpose: ten minutes counted in seconds is noise, and the HUD already
	-- draws that clock properly as MM:SS.
	countdown: boolean,
}

local STATE_DISPLAY: { [string]: StateDisplay } = {
	Lobby = { text = "WAITING FOR PLAYERS", playable = false, countdown = false },
	Voting = { text = "VOTING", playable = false, countdown = true },
	MapLoading = { text = "LOADING MAP", playable = false, countdown = false },
	WaitingToPlay = { text = "ROUND STARTING", playable = true, countdown = true },
	RoundActive = { text = "ROUND IN PROGRESS", playable = true, countdown = false },
	RoundResults = { text = "ROUND ENDING", playable = false, countdown = false },
}

--[[
	getState() is typed, but the value behind it came off a replicated table --
	a promise nobody kept (Match.luau's phrasing). A state this file has never
	heard of must read as "not yet": dark button, honest label. Blanking the
	label or defaulting to playable are the two ways that goes wrong.
]]
local UNKNOWN_STATE: StateDisplay = { text = "CONNECTING", playable = false, countdown = false }

local playButton: GuiButton? = nil
local playLabel: TextLabel? = nil
local playStatusLabel: TextLabel? = nil
local matchStatusLabel: TextLabel? = nil

-- The authored transparencies, read once at bind. See DISABLED_*_FADE.
local authoredBackgroundTransparency = 0
local authoredTextTransparency = 0

-- Which of OWNED_SCREENS were actually authored. Opening one that was not
-- would log a UIController warning on every phase change, all session.
local routable: { [string]: boolean } = {}

-- Paths a bind pass proved are not in the authored tree, and the warnings
-- already spent on them. Both survive a rebind on purpose -- see waitForPath.
local absent: { [string]: boolean } = {}
local warned: { [string]: boolean } = {}

-- 0 fully enabled, 1 fully disabled. Kept so a fade interrupted by a state
-- change resumes from where it actually is instead of snapping to an end
-- first -- the same reason UIController keeps its transition alpha.
local disabledAlpha = 0
local disabledHandle: Motion.Handle? = nil

-- nil until the first state lands, so the first apply always runs. Starting it
-- at `false` would make an opening state of RoundActive a silent no-op and
-- leave the button in whatever pose Studio happened to save it in.
local playEnabled: boolean? = nil

local lastRoutedPhase: string? = nil
local statusThread: thread? = nil

local MenuController = {}

-- Doubles as the key both once-only tables are indexed by, so a path is named
-- exactly one way whether it is being reported or remembered.
local function describe(root: Instance, path: { string }): string
	return `{root.Name}.{table.concat(path, ".")}`
end

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	log.warn(message)
end

--[[
	Walks a path of child names against ONE shared deadline.

	WaitForChild at every hop rather than only the first: PlayerGui is populated
	by replication from StarterGui, and a deep descendant can arrive frames
	after its ancestor. A FindFirstChild past the first hop is a race that
	happens to pass on a fast machine and fails on a loaded one.

	The deadline is checked before each hop instead of being divided between
	them, so a screen whose middle is missing costs the same bounded wait as one
	missing outright -- and never passes 0 to WaitForChild, whose behaviour at
	exactly zero is not something to rely on.

	A path proven missing is remembered across rebinds, because the copy
	re-cloned on the next respawn is the same authored tree and a second wait
	can only reach the same answer ten seconds later. Those ten seconds are not
	free here the way they are at join: attachLoop re-routes after them, so
	spending them again would leave a respawning player looking at the main
	menu while the round runs behind it.

	Only a timeout that had ABSENCE_PROOF_WINDOW seconds to run is recorded.
	Running out of the SHARED budget says nothing about the path -- it says
	another lookup spent the time -- and recording that would blacklist a path
	that is genuinely authored, for the rest of the session.
]]
local function waitForPath(root: Instance, path: { string }, deadline: number): Instance?
	local key = describe(root, path)
	if absent[key] then
		return nil
	end

	local current = root
	for _, name in path do
		local remaining = deadline - os.clock()
		if remaining <= 0 then
			return nil
		end
		local child = current:WaitForChild(name, remaining)
		if child == nil then
			absent[key] = remaining >= ABSENCE_PROOF_WINDOW
			return nil
		end
		current = child
	end
	return current
end

local function findLabel(root: Instance, path: { string }, deadline: number): TextLabel?
	local key = describe(root, path)
	local instance = waitForPath(root, path, deadline)
	if instance == nil then
		warnOnce(key, `{key} is missing -- that part of the menu will not update`)
		return nil
	end
	if not instance:IsA("TextLabel") then
		-- Blacklisted as well as reported: the class is a property of the
		-- authored tree, so re-walking it on every respawn only re-learns it.
		absent[key] = true
		warnOnce(key, `{key} is a {instance.ClassName}, not a TextLabel -- ignoring it`)
		return nil
	end
	return instance
end

local function findButton(root: Instance, path: { string }, deadline: number): GuiButton?
	local key = describe(root, path)
	local instance = waitForPath(root, path, deadline)
	if instance == nil then
		warnOnce(key, `{key} is missing -- that button will do nothing`)
		return nil
	end
	if not instance:IsA("GuiButton") then
		absent[key] = true
		warnOnce(key, `{key} is a {instance.ClassName}, not a GuiButton -- ignoring it`)
		return nil
	end
	return instance
end

local function openRoutable(name: string)
	if not routable[name] then
		return
	end
	UIController.open(name)
end

-- isOpen is false for a screen that was never authored, so this doubles as the
-- guard that keeps UIController quiet about screens this build may not ship.
local function closeIfOpen(name: string)
	if UIController.isOpen(name) then
		UIController.close(name)
	end
end

--[[
	Whole seconds for a countdown label.

	Ceil, not floor: a label sitting on "0s" for a whole second before anything
	happens reads as a freeze. NaN defeats math.max -- both of its comparisons
	are false -- so it is rejected BEFORE the clamp rather than after
	(quality-gate.md trap #8), which matters because PhaseEndsAt is a
	replicated number and arithmetic on a half-written one can produce it.
]]
local function countdownSeconds(): number
	local remaining = MatchController.secondsRemaining()
	if remaining ~= remaining then
		return 0
	end
	return math.max(0, math.ceil(remaining))
end

--[[
	Makes PLAY look the way it behaves (design brief 18). A button that merely
	does nothing is indistinguishable from a broken one, and players press a
	dead button repeatedly before they blame the game rather than themselves.
]]
local function applyPlayEnabled(button: GuiButton, label: TextLabel?, enabled: boolean)
	if playEnabled == enabled then
		return
	end
	playEnabled = enabled

	--[[
		Interactivity flips instantly rather than at the end of the fade: it has
		to be true the moment the state changed, not a quarter second later.

		Activated is the event to wire, and Active is what gates it.
		MouseButton1Click fires whether or not a button is Active, so a
		"disabled" button hung off Click is disabled in appearance only.
	]]
	button.Active = enabled
	button.AutoButtonColor = enabled

	if disabledHandle ~= nil then
		-- Cancel rather than let it finish, so a fast Voting -> WaitingToPlay
		-- flip starts from where the fade actually got to and reads as one
		-- movement instead of a snap back to full.
		disabledHandle.cancel()
		disabledHandle = nil
	end

	-- One proxy tween driving both properties, which is exactly what
	-- Motion.value exists for: two independent tweens are two things to cancel
	-- and two chances for the text and the panel to disagree mid-fade.
	disabledHandle = Motion.value(disabledAlpha, if enabled then 0 else 1, "smooth", function(alpha)
		disabledAlpha = alpha
		button.BackgroundTransparency = math.min(1, authoredBackgroundTransparency + DISABLED_BACKGROUND_FADE * alpha)
		if label ~= nil then
			label.TextTransparency = math.min(1, authoredTextTransparency + DISABLED_TEXT_FADE * alpha)
		end
	end, function()
		disabledHandle = nil
	end)
end

local function refreshStatus()
	local state: Match.MatchState = MatchController.getState()
	local display = STATE_DISPLAY[state] or UNKNOWN_STATE

	local text = display.text
	if display.countdown then
		local seconds = countdownSeconds()
		if seconds > 0 then
			-- Only when there IS a deadline: secondsRemaining() returns 0 for a
			-- phase with PhaseEndsAt == 0, and "VOTING — 0s" is a worse answer
			-- than "VOTING".
			text = `{display.text} — {seconds}s`
		end
	end

	if playStatusLabel ~= nil then
		playStatusLabel.Text = text
	end
	if matchStatusLabel ~= nil then
		matchStatusLabel.Text = text
	end

	local button = playButton
	if button ~= nil then
		applyPlayEnabled(button, playLabel, display.playable)
	end
end

local function stopStatusLoop()
	local thread = statusThread
	if thread == nil then
		return
	end
	statusThread = nil

	-- task.cancel on a thread that already finished throws, and this runs from
	-- a UIController close listener -- taking that listener down would leave
	-- the transition system mid-swap.
	if coroutine.status(thread) ~= "dead" then
		task.cancel(thread)
	end
end

--[[
	Ticks the countdown only while the menu is actually on screen (project rule
	5: nothing stays bound for a thing the player cannot see). Started on open,
	cancelled on close, and re-entrant-safe because the first thing it does is
	stop whatever was already running.
]]
local function startStatusLoop()
	stopStatusLoop()

	-- Immediately, not on the first tick: reopening the menu must not show half
	-- a second of the countdown the player left behind.
	refreshStatus()

	statusThread = task.spawn(function()
		while true do
			task.wait(STATUS_INTERVAL)
			refreshStatus()
		end
	end)
end

--[[
	Drops every reference into the PlayerGui copy that is on its way out.

	The Activated connections need no disconnecting -- Destroy() takes an
	instance's own connections with it -- but the two things that outlive the
	tree do: the ticker would go on writing whole seconds into destroyed labels
	forever, and a fade in flight would go on driving a destroyed button. Note
	that UIController fires no onClose for a screen that is destroyed rather
	than closed, so the ticker has to be stopped from here.

	Clearing playEnabled is the subtle half. The re-cloned button arrives in its
	AUTHORED pose, which is the ENABLED look; a cached `false` would make the
	next apply an early return and leave a dead button looking pressable.
	disabledAlpha goes back to 0 for the same reason -- it describes a button
	that no longer exists.
]]
local function unbind()
	stopStatusLoop()

	if disabledHandle ~= nil then
		disabledHandle.cancel()
		disabledHandle = nil
	end

	playButton = nil
	playLabel = nil
	playStatusLabel = nil
	matchStatusLabel = nil

	playEnabled = nil
	disabledAlpha = 0

	table.clear(routable)
end

--[[
	Opens the one screen this phase calls for and closes the ones it does not.

	Open BEFORE closing, deliberately: UIController overlaps an exclusive swap
	on purpose, and closing first would hand the player a frame of nothing.
]]
local function route(phase: Match.PlayerPhase)
	if lastRoutedPhase == phase then
		--[[
			Re-routing a phase the player is already in is not a navigation
			event, and treating it as one has a visible cost: open("MainMenu")
			closes every other exclusive screen, so a redundant route would slam
			the Shop shut under someone who had just opened it.
		]]
		return
	end
	lastRoutedPhase = phase

	local target = PHASE_SCREEN[phase]
	if target == nil then
		-- A phase this build does not know is not a reason to blank the screen.
		log.warn(`unknown player phase "{phase}" -- leaving the screens where they are`)
		return
	end

	openRoutable(target)

	for _, name in OWNED_SCREENS do
		if name ~= target then
			closeIfOpen(name)
		end
	end

	if target ~= "MainMenu" then
		for _, name in MENU_OVERLAYS do
			closeIfOpen(name)
		end
	end
end

local function bindPlayButton(mainMenu: Instance, deadline: number)
	local button = findButton(mainMenu, { "Root", "Actions", "PlayButton" }, deadline)
	if button == nil then
		return
	end

	playButton = button
	authoredBackgroundTransparency = button.BackgroundTransparency

	local label = findLabel(mainMenu, { "Root", "Actions", "PlayButton", "TextLabel" }, deadline)
	playLabel = label
	if label ~= nil then
		authoredTextTransparency = label.TextTransparency
	end

	playStatusLabel = findLabel(mainMenu, { "Root", "Actions", "PlayButton", "StatusLabel" }, deadline)

	button.Activated:Connect(function()
		--[[
			Active = false already stops Activated, so this guard only covers the
			window between the state changing and the restyle landing. It is
			presentation either way: the SERVER decides what PLAY means right now
			(Net.luau, requestPlay), and a refusal comes back as Net.notice.
		]]
		if playEnabled ~= true then
			return
		end
		Net.requestPlay.send()
	end)
end

local function bindMenuButtons(mainMenu: Instance, deadline: number)
	for _, entry in MENU_BUTTONS do
		local button = findButton(mainMenu, entry.path, deadline)
		if button == nil then
			continue
		end

		local screen = entry.screen
		button.Activated:Connect(function()
			-- Not toggle: these are exclusive screens reached from a button the
			-- overlay covers, so a second press can never be a "close".
			UIController.open(screen)
		end)
	end
end

local function bindOverlayCloseButtons(screens: Instance, deadline: number)
	for _, name in MENU_OVERLAYS do
		local key = describe(screens, { name })
		local screen = waitForPath(screens, { name }, deadline)
		if screen == nil then
			-- Not a warning: Inventory and Shop are placeholders in this build,
			-- and a screen nobody authored has no close button to miss.
			if not warned[key] then
				warned[key] = true
				log.debug(`no Screens.{name} authored -- no close button to wire`)
			end
			continue
		end

		local closeButton = findButton(screen, OVERLAY_CLOSE_PATH, deadline)
		if closeButton == nil then
			continue
		end

		closeButton.Activated:Connect(function()
			-- Back to MainMenu, not merely closed. Closing an exclusive screen
			-- on its own leaves the player looking at the bare 3D scene with
			-- nothing to click and no way to work out what happened.
			openRoutable("MainMenu")
		end)
	end
end

--[[
	Binds the menu, routes it, and then does the whole thing again after the
	next respawn.

	The loop is not defensive padding. StarterGui.ResetPlayerGuiOnSpawn is on by
	default and wipes PlayerGui on EVERY respawn, and in this game a player
	respawns every few seconds. Bind once and, from the first death onwards:

	  - PLAY is a connection on a destroyed instance and never fires again,
	  - the status labels take writes that land on nothing,
	  - the overlay CloseButtons die with it, which turns an exclusive Shop
	    into a softlock with no route back to the game.

	None of those raise an error to find. UIController re-registers the
	replacement screens for exactly this reason, and HUDController runs the same
	loop for exactly this reason.

	Re-ROUTING matters as much as re-binding, and is the part that is easy to
	miss: the re-cloned screens come back at their AUTHORED Enabled state, which
	is MainMenu open and HUD closed. Rebinding without routing would leave a
	player who respawned mid-round staring at the main menu with the round
	running behind it.

	Destroying:Wait() rather than a connection, as in HUDController: there is no
	handle to forget to disconnect, and this thread has nothing else to do in
	the meantime.
]]
local function attachLoop()
	local playerGui = player:WaitForChild("PlayerGui")

	while true do
		local screens = playerGui:WaitForChild("Screens", BIND_TIMEOUT)
		if screens == nil then
			log.warn("no PlayerGui.Screens folder -- there is nothing to route")
			return
		end

		--[[
			The budget starts once the folder is in hand. Started before the wait
			above, a slow-replicating folder would eat most of it and every
			lookup below would then fail against time that was never theirs.
		]]
		local deadline = os.clock() + BIND_TIMEOUT

		local mainMenu: Instance? = nil
		for _, name in OWNED_SCREENS do
			local key = describe(screens, { name })
			local screen = waitForPath(screens, { name }, deadline)
			if screen == nil then
				warnOnce(key, `no Screens.{name} authored -- that phase will leave the screen where it is`)
				continue
			end
			routable[name] = true
			if name == "MainMenu" then
				mainMenu = screen
			end
		end

		if mainMenu ~= nil then
			bindPlayButton(mainMenu, deadline)
			bindMenuButtons(mainMenu, deadline)
			matchStatusLabel = findLabel(mainMenu, { "Root", "MatchStatus", "TextLabel" }, deadline)
		end

		--[[
			Routed HERE rather than after the overlay pass below, and the reset
			is what makes it a route rather than a no-op.

			The reset: a phase listener that primed before this pass had anything
			routable will have recorded the phase while openRoutable was still
			dropping it on the floor. Only a bind pass knows what is on screen,
			so only a bind pass may decide the route is already correct.

			The position: this is the earliest point the answer is available, and
			everything after it waits on screens this build may not author. It is
			also safely after MainMenu's own descendants have been walked, which
			is what guarantees UIController has registered the replacement
			ScreenGui -- it registers on the ScreenGui arriving, and the labels
			above sit several hops deeper than that.
		]]
		lastRoutedPhase = nil
		route(MatchController.getPhase())

		bindOverlayCloseButtons(screens, deadline)

		--[[
			UIController registers a screen with `open = gui.Enabled`, which means
			the authored-open MainMenu never fires onOpen. So the ticker is started
			from the live answer here, and the listeners only handle later swaps.
		]]
		if UIController.isOpen("MainMenu") then
			startStatusLoop()
		else
			-- Still refresh once: the labels are behind a closed screen now, but a
			-- reopen should not flash the Studio placeholder text first.
			refreshStatus()
		end

		screens.Destroying:Wait()
		unbind()

		--[[
			Destroying fires while the folder is still parented, so an immediate
			WaitForChild("Screens") can be handed back the very instance that is
			on its way out -- and the whole pass above would then bind to a
			corpse and wait forever for it to be destroyed again.
		]]
		while playerGui:FindFirstChild("Screens") == screens do
			playerGui.ChildRemoved:Wait()
		end
	end
end

function MenuController.Start()
	--[[
		Listeners first, current values second. The other order has a gap: a
		phase that changed between reading getPhase() and registering would
		never be seen again, and the player would sit on the wrong screen until
		something else moved. Routing and the status refresh are both
		idempotent, so the duplicate work this ordering can cause is free --
		DataController.Init makes the same trade for the same reason.

		Registered out here rather than inside attachLoop, for the reason
		HUDController gives: a rebind must not stack a second listener on every
		respawn. They fire into module state that is nil until a pass binds it,
		and each pass refreshes from the live values itself to pick up whatever
		it missed.
	]]
	MatchController.onPhaseChanged(function(phase: Match.PlayerPhase)
		route(phase)
	end)
	MatchController.onStateChanged(function()
		-- Immediately as well as on the tick, so PLAY flips the instant the
		-- state does rather than up to STATUS_INTERVAL later.
		refreshStatus()
	end)

	UIController.onOpen("MainMenu", startStatusLoop)
	UIController.onClose("MainMenu", stopStatusLoop)

	-- Never returns: it is parked on the next respawn from here on. Start() is
	-- spawned per module (Loader.luau), so nothing is waiting behind it.
	attachLoop()
end

return MenuController
