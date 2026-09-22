--!strict
--[[
	The team picker: one button per side the round plays with (two or four),
	a live count on each, and a lock that is a prediction rather than a
	decision.

	WHAT THIS FILE DELIBERATELY DOES NOT DO

	It never opens or closes the TeamSelect screen. MenuController does that
	from MatchController.getPhase(), because the phase is what decides which
	screen a player is looking at, and two controllers writing one screen's
	visibility is a screen that flickers between them on every phase change.
	This file only fills in what is inside it.

	It never listens for Net.notice either. The server answers a refused team
	with one -- "RED TEAM IS FULL", ParticipantService.onRequestTeam -- and
	HUDController draws every notice there is. A second listener here would at
	best draw the same line twice, and at worst invite someone to "handle" the
	team notice here and leave the HUD silent about it for everyone else.

	THE COUNTS ARE COUNTED, NOT ASKED FOR

	The round replica holds no Red or Blue total, on purpose: a stored count is
	a second copy of the roster, and the failure mode of one missed decrement
	is a side that is permanently one slot short with nothing in the log to say
	so. TeamService.luau makes that argument server-side and it is the reason
	there is nothing on the wire to read instead. Under fifty rows, re-counted
	on every write to Players, is free.

	THE LOCK IS PRESENTATION

	A greyed side means "the server will almost certainly refuse this", never
	"this is refused". The real check runs inside TeamService.assign at the
	instant the packet is processed, against a roster this client cannot see
	and after however many other players pressed the same button in the same
	frame. The prediction here is therefore allowed to be wrong, and when it is
	wrong the server's notice is the only thing that tells the player -- which
	is exactly why nothing in this file may swallow a press the lock did not
	already stop.

	THE SCREEN IS RE-FOUND, NOT FOUND ONCE

	StarterGui.ResetPlayerGuiOnSpawn is on by default and wipes and re-clones
	the whole of PlayerGui on every respawn -- and in this game a player
	respawns every few seconds. A picker bound once at join is therefore a
	destroyed instance from the first death onwards, and every write to it
	after that lands on nothing with no error to find. So attachLoop() parks
	for the session and re-binds the replacement, the same shape
	HUDController.attachLoop uses and for the same reason UIController keeps
	watching PlayerGui rather than scanning it once.

	No Init(): there is nothing to register before the data arrives. The one
	thing this controller reads is MatchController.observe, which fires
	immediately with the current value however late it is registered, and the
	packets it sends are answered by services, not by listeners here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local Match = require(ReplicatedStorage.Shared.Match)
local MatchController = require(script.Parent.MatchController)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("TeamSelectController")

local player = Players.LocalPlayer

--[[
	One budget for the WHOLE bind, not one per WaitForChild. This screen is
	several lookups deep, and a timeout per call turns "TeamSelect was never
	authored" into a minute of a Start() that looks hung, when the honest
	answer was available after the first ten seconds.

	Spent afresh on each attach, never once for the session: a deadline taken
	at join has long expired by the first respawn, and a rebind measured
	against it would fail instantly against a clock rather than against the
	tree it is looking at.
]]
local BIND_TIMEOUT = 10

local SCREEN_NAME = "TeamSelect"

-- My row in Round.Players. Constant for the session; a UserId never changes.
local SELF_KEY = Match.playerKey(player.UserId)

--[[
	The locked look. The team colour is blended TOWARDS grey rather than
	replaced by it, so a locked side is still recognisably Red or Blue -- the
	player has to see which button is unavailable, not merely that one is. The
	word on NameLabel and the LockedLabel carry the message; colour never
	carries it alone (Match.luau, TeamDefinition.Color).
]]
local LOCKED_COLOR = Color3.fromRGB(92, 94, 102)
local LOCKED_COLOR_BLEND = 0.75
local LOCKED_TEXT_TRANSPARENCY = 0.55
local LOCKED_TRANSPARENCY_BOOST = 0.35

type Side = {
	definition: Match.TeamDefinition,
	button: GuiButton,
	colorBar: GuiObject?,
	nameLabel: TextLabel?,
	countLabel: TextLabel?,
	lockedLabel: GuiObject?,
	--[[
		The authored look, captured once at bind. Unlocking restores THESE
		rather than a constant, so a button retuned in Studio's property panel
		still looks the way it was drawn after its first lock and unlock.
	]]
	baseTransparency: number,
	baseAutoButtonColor: boolean,
	baseSelectable: boolean,
	baseNameTransparency: number,
	baseCountTransparency: number,
	-- nil until the first apply, so the authored state is always written once
	-- rather than assumed to be the unlocked one.
	locked: boolean?,
}

local sides: { Side } = {}
local connections: { RBXScriptConnection } = {}
-- False whenever `sides` does not describe live instances: before the first
-- attach, and between a screen's Destroying and the next one's bind.
local bound = false

local TeamSelectController = {}

--[[
	Walks `path` under `root`, waiting for each segment but never past
	`deadline`. nil and one warning if a segment never arrives -- a
	half-authored screen should cost the developer a line of output and the
	player a dead panel, never an error that takes the rest of Start() with it.
]]
local function waitForPath(root: Instance, path: { string }, deadline: number): Instance?
	local current: Instance = root
	for _, name in path do
		local child = current:WaitForChild(name, math.max(deadline - os.clock(), 0))
		if child == nil then
			log.warn(`{current:GetFullName()} has no "{name}" -- TeamSelect is missing part of its authored tree`)
			return nil
		end
		current = child
	end
	return current
end

--[[
	A decoration inside a button. Optional by design: every caller nil-guards
	it, so a missing CountLabel costs one number on screen and nothing else.
]]
local function findLabel(parent: Instance, name: string): TextLabel?
	local child = parent:FindFirstChild(name)
	if child == nil or not child:IsA("TextLabel") then
		log.warn(`{parent:GetFullName()} has no {name} TextLabel -- that part of the button stays as authored`)
		return nil
	end
	return child
end

local function findGuiObject(parent: Instance, name: string): GuiObject?
	local child = parent:FindFirstChild(name)
	if child == nil or not child:IsA("GuiObject") then
		log.warn(`{parent:GetFullName()} has no {name} GuiObject -- that part of the button stays as authored`)
		return nil
	end
	return child
end

local function applyLock(side: Side, locked: boolean)
	if side.locked == locked then
		return
	end
	side.locked = locked

	--[[
		Active = false is what actually stops the press: a GuiButton with
		Active false never fires Activated. The greying and the refusal are
		therefore the same switch and cannot disagree -- a button that looks
		dead but still sends, or one that looks live but silently does nothing,
		are both impossible to reach from here.
	]]
	side.button.Active = not locked
	side.button.AutoButtonColor = if locked then false else side.baseAutoButtonColor
	-- Gamepad focus must skip a locked side too, or the stick lands on a
	-- highlighted button that cannot be pressed.
	side.button.Selectable = if locked then false else side.baseSelectable

	local transparency = math.clamp(side.baseTransparency + LOCKED_TRANSPARENCY_BOOST, 0, 1)
	side.button.BackgroundTransparency = if locked then transparency else side.baseTransparency

	if side.colorBar ~= nil then
		local color = side.definition.Color
		side.colorBar.BackgroundColor3 = if locked then color:Lerp(LOCKED_COLOR, LOCKED_COLOR_BLEND) else color
	end
	if side.nameLabel ~= nil then
		side.nameLabel.TextTransparency = if locked then LOCKED_TEXT_TRANSPARENCY else side.baseNameTransparency
	end
	if side.countLabel ~= nil then
		side.countLabel.TextTransparency = if locked then LOCKED_TEXT_TRANSPARENCY else side.baseCountTransparency
	end
	if side.lockedLabel ~= nil then
		-- Visibility only. Whatever it says is Studio's copy, and rewriting it
		-- here would be a second place to change the wording from.
		side.lockedLabel.Visible = locked
	end
end

--[[
	Red and Blue, plus MY side, read off the replicated roster.

	My own row is excluded from the two counts and returned separately because
	the server frees my current slot before it tests the one I am asking for:
	TeamService.assign drops me from the roster and only then calls canJoin.
	Counting myself on the side I already hold would lock the very switch that
	would have evened the teams out.

	Every value is re-validated even though RoundPlayer says what it is -- this
	is a replicated table, and its static type is a promise made on another
	machine.
]]
local function countSides(players: any): ({ [string]: number }, string)
	local counts: { [string]: number } = {}
	for _, teamId in Match.TEAM_ORDER do
		counts[teamId] = 0
	end

	local mine = ""
	if type(players) ~= "table" then
		return counts, mine -- the replica has not landed yet
	end

	for key, entry in players do
		if type(entry) ~= "table" then
			continue
		end

		local team = entry.Team
		if key == SELF_KEY then
			mine = if type(team) == "string" then team else ""
			continue
		end

		-- "" for a player still in the menu and for everyone in Free For All,
		-- so an unpicked side is counted towards neither.
		if type(team) == "string" and counts[team] ~= nil then
			counts[team] += 1
		end
	end

	return counts, mine
end

--[[
	Would one more player on `team` put the largest and smallest of `teams`
	further apart than Config.Teams.MaxImbalance? `counts` must already
	exclude me. The client mirror of TeamService.canJoin; the two must agree.

	It answers for a player who is on NO team, which is the same question
	canJoin answers and the only one it can answer -- the caller is what has to
	notice that I already hold the side being tested, because the server skips
	the balance check outright in that case.
]]
local function wouldExceedImbalance(team: Match.TeamId, counts: { [string]: number }, teams: { Match.TeamId }): boolean
	local largest, smallest = -math.huge, math.huge
	for _, side in teams do
		local count = (counts[side] or 0) + (if side == team then 1 else 0)
		largest = math.max(largest, count)
		smallest = math.min(smallest, count)
	end
	return largest - smallest > Config.Teams.MaxImbalance
end

local function refresh()
	if not bound then
		--[[
			No screen right now: either PlayerGui is mid-re-clone, or the
			authored tree was incomplete and attachLoop gave up. MatchController
			.observe has no unsubscribe, so this listener outlives the instances
			it was registered for and has to check rather than assume.
		]]
		return
	end

	--[[
		Read out of the round rather than taken as an argument, so the observer
		fire and the explicit call attachLoop makes after each bind are the
		same code path. A bind that had to reconstruct "the last value observe
		handed us" is a second copy of the roster and a second thing to get
		stale.
	]]
	local round = MatchController.getRound()
	local counts, mine = countSides(if round ~= nil then round.Players else nil)
	local mode = MatchController.getTeamMode()

	for _, side in sides do
		-- Annotated: an unannotated local taking a field under refinement
		-- loses the singleton union, and the helpers below want TeamId.
		local teamId: Match.TeamId = side.definition.Id

		--[[
			Only the round's own sides are on offer. A Green button in a
			two-team round would be a button the server refuses every time
			(ParticipantService checks the mode's team list), so it is not
			shown at all. The Options layout fills the width with whichever
			buttons are visible.
		]]
		local inMode = Match.modeHasTeam(mode, teamId)
		side.button.Visible = inMode
		if not inMode then
			continue
		end

		if side.countLabel ~= nil then
			local count = counts[teamId] or 0
			if mine == teamId then
				-- My row, put back for the LABEL only. The prediction below
				-- leaves it out because the server does; a player reading the
				-- screen is owed the real number of people on that side.
				count += 1
			end
			side.countLabel.Text = if count == 1 then "1 PLAYER" else `{count} PLAYERS`
		end

		--[[
			Re-asserting the side I already hold is accepted by the server
			without a balance check at all (TeamService.assign returns early on
			`previous == team`), so greying it would be predicting a refusal
			that cannot happen -- and it would happen exactly when the sides are
			already further apart than MaxImbalance, which is the moment the
			screen most needs to read honestly.
		]]
		applyLock(side, mine ~= teamId and wouldExceedImbalance(teamId, counts, mode.Teams))
	end
end

--[[
	Drops the bound screen. `bound` is cleared FIRST, so a refresh racing the
	teardown skips the instances on their way out instead of writing to them.

	No warning here, unlike the instances themselves: a destroyed TeamSelect is
	the normal consequence of a respawn, and attachLoop binds the replacement.
]]
local function teardown()
	bound = false
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	table.clear(sides)
end

local function bindSide(options: Instance, teamId: Match.TeamId, deadline: number)
	--[[
		The authored name is the team id plus "Button", so a third team is a
		Match.TEAM_ORDER entry and a button in Studio -- nothing in this file.
		(The balance rule above would still need a rewrite; the wiring would
		not.)
	]]
	local instance = waitForPath(options, { `{teamId}Button` }, deadline)
	if instance == nil then
		return
	end
	if not instance:IsA("GuiButton") then
		log.warn(`{instance:GetFullName()} is a {instance.ClassName}, not a button -- {teamId} cannot be picked`)
		return
	end

	local definition = Match.TEAMS[teamId]
	local nameLabel = findLabel(instance, "NameLabel")
	local countLabel = findLabel(instance, "CountLabel")

	local side: Side = {
		definition = definition,
		button = instance,
		colorBar = findGuiObject(instance, "ColorBar"),
		nameLabel = nameLabel,
		countLabel = countLabel,
		lockedLabel = findGuiObject(instance, "LockedLabel"),
		baseTransparency = instance.BackgroundTransparency,
		baseAutoButtonColor = instance.AutoButtonColor,
		baseSelectable = instance.Selectable,
		baseNameTransparency = if nameLabel ~= nil then nameLabel.TextTransparency else 0,
		baseCountTransparency = if countLabel ~= nil then countLabel.TextTransparency else 0,
		locked = nil,
	}

	if nameLabel ~= nil then
		-- Written from Match.TEAMS rather than left as authored: the word is
		-- what carries the meaning for the roughly one player in twelve who
		-- cannot separate these two hues, and one source for it beats two.
		nameLabel.Text = definition.DisplayName
	end
	if side.colorBar ~= nil then
		side.colorBar.BackgroundColor3 = definition.Color
	end
	if side.lockedLabel ~= nil then
		-- Hidden whichever state Studio left it in: a designer has to be able
		-- to see it while drawing the locked look, and a player must not see
		-- it on the frame the screen opens. The first refresh decides.
		side.lockedLabel.Visible = false
	end

	table.insert(
		connections,
		instance.Activated:Connect(function()
			--[[
				Sent unconditionally, and that is the whole point of the lock
				being presentation. A locked button cannot fire this at all, so
				a second `if locked then return end` here could only ever
				discard a press the prediction got WRONG -- and it would
				discard it silently, because a packet that was never sent
				cannot come back as a notice. The server re-checks at the
				moment it processes this and answers when it refuses.
			]]
			Net.requestTeam.send({ team = side.definition.Id })
		end)
	)

	table.insert(sides, side)
end

--[[
	Wires one TeamSelect screen. False if its authored tree is incomplete --
	the caller must not retry on that, because the copy re-cloned on the next
	respawn is the same tree and would only repeat the same warning on a loop.
]]
local function attach(screen: ScreenGui, deadline: number): boolean
	local options = waitForPath(screen, { "Root", "Panel", "Options" }, deadline)
	if options == nil then
		return false
	end

	-- Annotated loop variable: Match.TEAM_ORDER is written as
	-- `{ "Red", "Blue" } :: { TeamId }`, but a table-property assignment
	-- widens the singletons back to `{ string }`.
	for _, teamId: Match.TeamId in Match.TEAM_ORDER do
		bindSide(options, teamId, deadline)
	end

	if #sides == 0 then
		log.warn("TeamSelect has no usable team buttons -- a player in Team Deathmatch cannot join")
		return false
	end

	local backButton = waitForPath(screen, { "Root", "Panel", "BackButton" }, deadline)
	if backButton == nil then
		-- waitForPath has already named the missing instance; this is the cost
		-- of it, which that helper has no way to know. Not fatal: a picker with
		-- no way back still lets a player pick, and MenuController leaves the
		-- phase for them when the round does.
		log.warn("TeamSelect has no BackButton -- a player who opened it cannot back out")
	elseif not backButton:IsA("GuiButton") then
		log.warn(`{backButton:GetFullName()} is a {backButton.ClassName}, not a button -- backing out will not work`)
	else
		table.insert(
			connections,
			backButton.Activated:Connect(function()
				--[[
					"Put me back in the menu." Not a screen swap done here:
					leaving is a server decision that releases the code, the
					team slot and the character, and MenuController follows the
					phase back to Menu once it has. Closing the screen locally
					would show a menu to a player the server still has in
					TeamSelect.
				]]
				Net.requestLeaveMatch.send()
			end)
		)
	end

	return true
end

--[[
	The live Screens folder, or nil once the budget is spent.

	`Parent ~= nil` is the part that earns the poll. PlayerGui is cleared and
	re-cloned in one go, so for a frame either side of a respawn the old,
	doomed folder is still a child of PlayerGui -- and WaitForChild would hand
	that one back. We would then search a tree that is already empty, spend the
	whole budget on it and give up, and the picker would be dead for the rest
	of the session over a one-frame race.
]]
local function waitForScreens(playerGui: Instance, deadline: number): Instance?
	while true do
		local screens = playerGui:FindFirstChild("Screens")
		if screens ~= nil and screens.Parent ~= nil then
			return screens
		end
		if os.clock() >= deadline then
			return nil
		end
		task.wait()
	end
end

--[[
	The TeamSelect ScreenGui, from anywhere under `screens`.

	Descendants rather than children, and re-scanned rather than waited on:
	subfolders under Screens are legal and are organisation only -- a screen is
	addressed by its own name, so Screens/Menus/TeamSelect is still just
	TeamSelect (UIController.considerChild). A WaitForChild would only ever see
	the direct-child spelling and would burn the entire budget before the
	fallback scan found the other one.

	IsA, not just the name: the recursive search would otherwise happily return
	a Frame someone called TeamSelect and we would bind the wrong tree.
]]
local function waitForScreen(screens: Instance, deadline: number): ScreenGui?
	while true do
		for _, descendant in screens:GetDescendants() do
			if descendant.Name == SCREEN_NAME and descendant:IsA("ScreenGui") then
				return descendant
			end
		end
		if os.clock() >= deadline then
			return nil
		end
		task.wait()
	end
end

--[[
	Finds the picker, drives it, and re-finds it for the rest of the session --
	see the header for why one bind is not enough. Parks forever; the Loader
	spawns every Start(), so nothing is waiting on this to return.
]]
local function attachLoop()
	local playerGui = player:WaitForChild("PlayerGui")

	while true do
		-- A fresh budget per attempt, for the reason BIND_TIMEOUT gives.
		local deadline = os.clock() + BIND_TIMEOUT

		local screens = waitForScreens(playerGui, deadline)
		local screen = if screens ~= nil then waitForScreen(screens, deadline) else nil

		if screen == nil then
			log.warn(`no PlayerGui.Screens.{SCREEN_NAME} after {BIND_TIMEOUT}s -- the team picker will not be drawn`)
			return
		end

		if not attach(screen, deadline) then
			-- attach() named what is missing, and said why retrying is wrong.
			teardown()
			return
		end

		bound = true

		--[[
			The counts a rebind missed. The observer below fires on writes, and
			between this screen's clone and the last one's death there may not
			have been any -- so the first paint is made here rather than waited
			for.
		]]
		refresh()

		screen.Destroying:Wait()
		teardown()
	end
end

function TeamSelectController.Start()
	--[[
		Registered once, here rather than inside attachLoop, so a rebind after
		a respawn does not stack a second observer on the roster. It fires into
		`bound`, which is false until the loop has a screen, and the loop
		refreshes itself after each bind to pick up whatever it missed
		(HUDController.Start makes the same split for the same reason).

		Fires immediately with the current roster and again on every write to
		it, so a player who opens this screen mid-round and one who was sitting
		on it when someone joined take the identical path -- there is no
		separate "populate on open" to forget.

		Left running while the screen is hidden on purpose. The work is two
		labels and a transparency, and gating it on the screen being open would
		need a refresh-on-open path that can only ever get out of step with
		this one.
	]]
	MatchController.observe({ "Players" }, refresh)
	-- Which buttons exist at all depends on the round's team mode.
	MatchController.observe({ "TeamModeId" }, refresh)

	attachLoop()
end

return TeamSelectController
