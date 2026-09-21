--!strict
--[[
	The main menu's player card: who you are, what level you are, how far
	through that level you are, and how much cash you have.

	Everything on it is a READ of the profile replica, and there is no packet in
	this file. Cash, Level and Experience are profile fields (Net.luau, "WHAT IS
	NOT IN HERE"); a `cashChanged` packet would be a second copy of the truth
	that drifts from the first the moment one is dropped. DataController.observe
	fires once with the current value AND again on every change, so a profile
	that lands late and a mid-session grant take the identical path -- there is
	no separate "populate when the menu opens" to forget.

	THE LEVEL-UP FLASH HAS NO PACKET, AND MUST NOT GET ONE

	observe hands its listener the previous value alongside the new one, so the
	client can already tell a level-up from a first read on its own. A server
	announcement would be a second source for something the replica has already
	said, and the two would disagree exactly when it matters -- a grant that
	crosses two levels at once fires one packet and moves Level twice.

	THE CARD IS REBOUND, NOT CAPTURED

	StarterGui.ResetPlayerGuiOnSpawn is on by default, so PlayerGui is wiped and
	re-cloned on every respawn -- and in this game the player dies, watches a
	killcam and comes back to this menu between rounds. A controller that held
	the labels it found at boot would be writing into destroyed instances from
	the first death onwards, and the card the player actually sees would sit at
	its authored placeholder text for the rest of the session with nothing in
	the log to say why. So the elements live in one `card` table, every write
	goes through it, and the screen's Destroying rebinds it -- the same shape
	ShowcaseController uses on this very screen, and HUDController on its own.

	Studio owns the card (ARCHITECTURE.md, "The map"). This controller finds the
	authored labels and writes their Text; it never builds one.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataController = require(script.Parent.DataController)
local Log = require(ReplicatedStorage.Shared.Log)
local Motion = require(script.Parent.Parent.UI.Motion)
local Progression = require(ReplicatedStorage.Shared.Progression)

local log = Log.new("PlayerCardController")

local player = Players.LocalPlayer

-- How long to wait for the authored MainMenu before deciding there isn't one.
-- Bounded so an unauthored screen costs one warning instead of a Start() that
-- never returns (HUDController.luau makes the same call).
local SCREEN_TIMEOUT = 10

-- From PlayerGui down, exactly as authored. UIController addresses screens by
-- name; anything that wants the instance itself walks this.
local SCREEN_PATH = { "Screens", "MainMenu" }
local ROOT_NAME = "Root"

-- The badge is a celebration, not a notification: long enough to read, gone
-- before the player has finished deciding what to click.
local LEVEL_UP_HOLD = 2

-- What the badge pops out of and back into. Both ends of the animation, so the
-- authored size is the only size it ever rests at.
local BADGE_COLLAPSED_SCALE = 0.6

--[[
	One clone of the authored card. Every field is optional because a missing
	element costs you that field and nothing else, and the two base sizes are
	read at bind time -- see bind() for why they cannot be read any later.
]]
type Card = {
	displayName: TextLabel?,
	username: TextLabel?,
	level: TextLabel?,
	experience: TextLabel?,
	badge: GuiObject?,
	badgeBase: UDim2,
	barFill: GuiObject?,
	barFillBase: UDim2,
	cash: TextLabel?,
}

local PlayerCardController = {}

-- nil before the first bind and between a PlayerGui reset and the rebind that
-- follows it. Every paint below starts by taking a local copy of it.
local card: Card? = nil
local attaching = false

--[[
	One warning per distinct message, not one per PlayerGui reset. An element
	nobody authored is just as missing on the rebind after every respawn, and
	forty identical lines bury the first -- which is the only one carrying any
	information. Keyed by message rather than by a single flag so a second
	missing element still gets said once (ShowcaseController.warnOnce, widened).
]]
local warned: { [string]: true } = {}

local function warnOnce(message: string)
	if warned[message] then
		return
	end
	warned[message] = true
	log.warn(message)
end

local barHandle: Motion.Handle? = nil
-- The X scale the bar is actually showing. Negative until the first render,
-- which is what stops a tween ever starting from a value nothing has drawn.
local shownProgress = -1
-- The level the bar was last drawn against. Drives the snap-vs-tween choice,
-- and its impossible starting value doubles as "nothing drawn yet".
local renderedLevel = -1

local badgeHandle: Motion.Handle? = nil
local badgeHideThread: thread? = nil

--[[
	The observers hand back whatever the replica holds, typed `any`, and
	everything below either does arithmetic on it or interpolates it into a
	label. Both fail quietly rather than loudly: a nil Experience renders the
	literal "nil" on screen, and a NaN survives math.clamp untouched -- both of
	its comparisons are false (quality-gate trap #8) -- all the way to a bar
	sized nan. Screening once here beats guarding at five call sites.
]]
local function numberOr(value: any, fallback: number): number
	if type(value) ~= "number" or value ~= value then
		return fallback
	end
	return value
end

--[[
	Thousands separators. "4,250" is read at a glance; "4250" has to be counted,
	and a pill the player looks at for half a second on their way to the Play
	button only ever gets the glance.

	An explicit loop rather than the usual reverse-gsub-reverse one-liner. That
	idiom emits a leading comma on any exact multiple of three digits -- "100"
	comes back as ",100" -- and it chains off a call result, which this codebase
	does not do (quality-gate trap #2).
]]
local function groupThousands(amount: number): string
	local whole = math.floor(amount)
	local sign = if whole < 0 then "-" else ""
	local digits = tostring(math.abs(whole))

	local grouped = ""
	local head = #digits
	while head > 3 do
		grouped = `,{string.sub(digits, head - 2, head)}{grouped}`
		head -= 3
	end

	return `{sign}{string.sub(digits, 1, head)}{grouped}`
end

--[[
	Walks a chain of children, waiting for each in turn against ONE shared
	deadline. A timeout per step multiplies: three missing steps at ten seconds
	each is half a minute of a Start() that failed in the first second. The
	deadline is passed in rather than started here so the screen lookup and the
	Root lookup share a single budget.
]]
local function waitForPath(from: Instance, path: { string }, deadline: number): Instance?
	local current = from

	for _, name in path do
		-- Never zero. WaitForChild(name, 0) gives up before replication has had
		-- a chance, which turns a slow join into a missing screen.
		local child = current:WaitForChild(name, math.max(deadline - os.clock(), 0.1))
		if child == nil then
			warnOnce(`no {from.Name}.{table.concat(path, ".")} authored -- the player card will not update`)
			return nil
		end
		current = child
	end

	return current
end

--[[
	Below Root a plain FindFirstChild is enough: PlayerGui's copy of a screen is
	cloned from StarterGui as one whole tree, so if Root is here its descendants
	are too. Getting to Root at all is the only real race, and waitForPath
	covers that one.

	A missing element is a warning and a nil, never an error. An unfinished card
	should cost you the one field nobody has authored yet, not every field.
]]
local function findLabel(parent: Instance, name: string): TextLabel?
	local child = parent:FindFirstChild(name)
	if child == nil or not child:IsA("TextLabel") then
		warnOnce(`{parent:GetFullName()}.{name} is missing or is not a TextLabel -- that field will not update`)
		return nil
	end
	return child
end

local function findObject(parent: Instance, name: string): GuiObject?
	local child = parent:FindFirstChild(name)
	if child == nil or not child:IsA("GuiObject") then
		warnOnce(`{parent:GetFullName()}.{name} is missing or is not a GuiObject -- that field will not update`)
		return nil
	end
	return child
end

local function stopBar()
	if barHandle ~= nil then
		barHandle.cancel()
		barHandle = nil
	end
end

local function stopBadge()
	if badgeHandle ~= nil then
		badgeHandle.cancel()
		badgeHandle = nil
	end
	if badgeHideThread ~= nil then
		task.cancel(badgeHideThread)
		badgeHideThread = nil
	end
end

--[[
	Sets the fill's X scale and leaves every other component of the authored
	size alone -- BarFill may well carry a Y offset or a padding inset, and
	rebuilding the whole UDim2 from constants would quietly undo it.

	`animate` is false when the level changed. A tween is what makes an ordinary
	gain readable, but after a level-up the target is LOWER than what is on
	screen, and animating there reads as losing XP rather than gaining a level.
]]
local function setBarProgress(fill: GuiObject, base: UDim2, target: number, animate: boolean)
	-- A gain that lands mid-tween retargets from wherever the bar has got to.
	-- Left running, the old tween keeps writing Size underneath the new one and
	-- the two fight for the whole overlap.
	stopBar()

	if not animate or shownProgress < 0 then
		shownProgress = target
		fill.Size = UDim2.new(target, 0, base.Y.Scale, base.Y.Offset)
		return
	end

	barHandle = Motion.value(shownProgress, target, "smooth", function(value)
		shownProgress = value
		fill.Size = UDim2.new(value, 0, base.Y.Scale, base.Y.Offset)
	end, function()
		barHandle = nil
	end)
end

local function collapse(size: UDim2, scale: number): UDim2
	return UDim2.new(size.X.Scale * scale, size.X.Offset * scale, size.Y.Scale * scale, size.Y.Offset * scale)
end

--[[
	Pops the badge in, holds it, pops it back out.

	Only Size and Visible are touched. The badge's colours and transparencies
	are Studio's, and a fade would have to guess what to fade back TO -- get
	that guess wrong, or interrupt the fade, and the badge is left permanently
	half-transparent, which is a bug nobody can explain by reading this file.

	Re-entrant on purpose. Two level-ups from one XP grant arrive as a single
	replica write, but a dev-console grant can produce two in quick succession,
	and the second must restart the badge rather than be swallowed by the
	first's pending hide.
]]
local function flashLevelUp(badge: GuiObject, base: UDim2)
	-- Including the previous flash's hide. Left running it would hide the badge
	-- LEVEL_UP_HOLD after the FIRST level-up, part-way through the second.
	stopBadge()

	badge.Size = collapse(base, BADGE_COLLAPSED_SCALE)
	badge.Visible = true
	badgeHandle = Motion.tween(badge, { Size = base }, "pop", function()
		badgeHandle = nil
	end)

	badgeHideThread = task.delay(LEVEL_UP_HOLD, function()
		-- Cleared FIRST, so a flash arriving later never task.cancels a thread
		-- that has already finished running.
		badgeHideThread = nil

		badgeHandle = Motion.tween(badge, { Size = collapse(base, BADGE_COLLAPSED_SCALE) }, "snappy", function()
			badgeHandle = nil
			badge.Visible = false
		end)
	end)
end

--[[
	Neither name comes from the profile, and that is not an oversight: the
	template (DataService.luau) holds Cash, Level, Experience, Inventory and
	Settings and no name at all. Roblox already owns both strings, a player can
	change their DisplayName mid-session -- at which point a saved copy is wrong
	until something writes it again -- and the Player instance is readable now
	rather than whenever the replica lands, so the card is never blank while
	data is in flight.
]]
local function paintIdentity(ui: Card)
	local displayNameLabel = ui.displayName
	if displayNameLabel ~= nil then
		displayNameLabel.Text = player.DisplayName
	end

	local usernameLabel = ui.username
	if usernameLabel ~= nil then
		-- The @ is not decoration. DisplayName and Name are frequently different
		-- strings, and nothing else on the card says which of the two this is.
		usernameLabel.Text = `@{player.Name}`
	end
end

--[[
	Level, XP and the bar, all re-read from the replica rather than taken from
	the observer that woke us.

	Both observers below fire from the SAME replica write -- LevelService writes
	Level and Experience in one setValues (LevelService.luau:106) and Replica
	notifies every intersecting listener from that one change -- so reading the
	pair fresh is what stops whichever observer ran first rendering the new
	level against the previous experience.

	No frame is drawn between the two fires, so a plain Size write would settle
	invisibly; but the bar TWEENS, and a tween started from that intermediate is
	a quarter second of the fill visibly walking back down from full. Reading
	both values fresh means there is no intermediate to start from. It is also
	what lets a rebind repaint the whole card with no cached copy to go stale.
]]
local function paintProgress()
	local ui = card
	if ui == nil then
		return -- no card bound (first frames, or between a reset and its rebind)
	end

	local data = DataController.getData()
	if data == nil then
		return -- observe only fires once the replica has landed; cheap guard
	end

	local level = numberOr(data.Level, Progression.MIN_LEVEL)
	local experience = numberOr(data.Experience, 0)

	local levelLabel = ui.level
	if levelLabel ~= nil then
		levelLabel.Text = `LEVEL {level}`
	end

	local experienceLabel = ui.experience
	if experienceLabel ~= nil then
		--[[
			MAX rather than a fraction at the cap. Progression.resolve zeroes
			Experience there on purpose -- left to accumulate it walks into
			2^53, where n + 1 == n -- so "0 / 5050 XP" would be an honest
			reading of a field that has stopped meaning anything.
		]]
		experienceLabel.Text = if Progression.isMaxLevel(level)
			then "MAX"
			else `{experience} / {Progression.experienceForLevel(level)} XP`
	end

	local barFill = ui.barFill
	if barFill ~= nil then
		-- Progression.progress, never a local copy of the curve: the client's
		-- bar and the server's rollover have to walk the identical curve or the
		-- bar sits at 90% while the player levels up anyway.
		setBarProgress(barFill, ui.barFillBase, Progression.progress(level, experience), level == renderedLevel)
	end

	renderedLevel = level
end

local function paintCash()
	local ui = card
	if ui == nil then
		return
	end

	local cashLabel = ui.cash
	if cashLabel == nil then
		return
	end

	local data = DataController.getData()
	if data == nil then
		return
	end

	cashLabel.Text = groupThousands(numberOr(data.Cash, 0))
end

--[[
	Finds this clone's elements.

	Both authored sizes are read HERE, before anything animates them. After the
	first flash or the first tween the live Size is mid-animation rather than
	authored, and an animation that reads its own output as its target creeps a
	little further every time it runs.
]]
local function bind(root: Instance): Card?
	local holder = findObject(root, "PlayerCard")
	if holder == nil then
		return nil
	end

	local badge = findObject(holder, "LevelUpBadge")
	local experienceBar = findObject(holder, "ExperienceBar")
	local barFill = if experienceBar ~= nil then findObject(experienceBar, "BarFill") else nil
	local cashPill = findObject(root, "CashPill")

	return {
		displayName = findLabel(holder, "DisplayNameLabel"),
		username = findLabel(holder, "UsernameLabel"),
		level = findLabel(holder, "LevelLabel"),
		experience = findLabel(holder, "ExperienceLabel"),
		badge = badge,
		badgeBase = if badge ~= nil then badge.Size else UDim2.new(),
		barFill = barFill,
		barFillBase = if barFill ~= nil then barFill.Size else UDim2.new(),
		cash = if cashPill ~= nil then findLabel(cashPill, "CashLabel") else nil,
	}
end

local attach: () -> ()

--[[
	Waits for this copy of MainMenu, binds it, paints it, and arranges to do the
	whole thing again for the copy that replaces it.

	Yields, so it belongs to Start() and to a task.spawn from the Destroying
	handler -- yielding inside a Destroying handler stalls whatever is doing the
	destroying.
]]
function attach()
	if attaching then
		return -- a rebind is already in flight; two would race to set `card`
	end
	attaching = true

	local playerGui = player:WaitForChild("PlayerGui")
	local deadline = os.clock() + SCREEN_TIMEOUT

	local screen = waitForPath(playerGui, SCREEN_PATH, deadline)
	local root = if screen ~= nil then waitForPath(screen, { ROOT_NAME }, deadline) else nil

	attaching = false

	if screen == nil or root == nil then
		return -- waitForPath has already said which step was missing
	end

	--[[
		No Disconnect needed: Destroying fires once and the connection dies with
		the instance that owns it. Clearing `card` first means an observer that
		fires during the gap paints nothing rather than writing into a destroyed
		label.
	]]
	screen.Destroying:Connect(function()
		card = nil
		stopBar()
		stopBadge()
		-- The replacement is authored identically, so the next bind starts from
		-- authored sizes again and nothing drawn against the old clone carries
		-- over.
		shownProgress = -1
		renderedLevel = -1
		task.spawn(attach)
	end)

	local bound = bind(root)
	card = bound
	if bound == nil then
		return -- bind() named the element that is missing
	end

	-- Paint immediately rather than waiting for the next replica write: the
	-- observers below fire once on binding and then only on a change, which on a
	-- rebind was already spent on the clone that has just been destroyed. Before
	-- the profile lands each paint is a cheap no-op and the observers do it.
	paintIdentity(bound)
	paintProgress()
	paintCash()
end

--[[
	Nothing to register. The one listener that has to exist before the server
	sends anything is Replica.OnNew, and DataController owns it (Priority 100,
	registered in its own Init) -- observe() waits on that internally, so it is
	safe to call from Start. This controller listens to no packets, so there is
	nothing here that could miss an early event.
]]
function PlayerCardController.Init() end

function PlayerCardController.Start()
	--[[
		Level and Experience are watched separately rather than as one observer
		on the profile root, because only the Level observer can see a level-up:
		a root watch is handed the whole Data table as both value and old, and
		that is the same table mutated in place -- comparing it to itself can
		never detect anything.
	]]
	DataController.observe({ "Level" }, function(value: any, old: any?)
		paintProgress()

		--[[
			`old == nil` is the first fire, not a level-up. observe deliberately
			calls its listener once with the current value and no previous one so
			a binding is a single call; congratulating every player on joining at
			whatever level they already were is the cost of ignoring that.
		]]
		if old == nil then
			return
		end

		--[[
			Strictly greater, and the fallbacks are chosen so anything unusable
			answers "no flash": the dev console can set a level DOWN, and a NaN
			written into the profile makes every comparison false either way.
		]]
		local previous = numberOr(old, math.huge)
		local current = numberOr(value, 0)
		if current <= previous then
			return
		end

		local ui = card
		if ui == nil then
			return
		end

		local badge = ui.badge
		if badge ~= nil then
			flashLevelUp(badge, ui.badgeBase)
		end
	end)

	DataController.observe({ "Experience" }, paintProgress)
	DataController.observe({ "Cash" }, paintCash)

	attach()
end

return PlayerCardController
