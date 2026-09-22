--!strict
--[[
	The fifteen-second ballot, drawn client side: pick a map, then a game mode
	(the ruleset), then a team mode, then watch the tally.

	The screen is authored in Studio and only found here (ARCHITECTURE.md, "The
	map"). The one thing this file creates is clones of the authored
	OptionTemplate and SummaryTemplate, which exist for exactly that.

	THE LAYOUT, top to bottom: a header (step counter, title, subtitle, and the
	timer on the right), a three-segment progress bar -- one segment per ballot
	-- and then either the options for the current ballot as full-width rows,
	or, once all three are cast, one summary row per ballot saying what is
	winning. Each option row carries a thin bar showing its share of that
	ballot's votes, so the tally reads at a glance instead of as three numbers
	to compare.

	WHY THE REBUILD IS GUARDED

	Two things move this panel, at very different rates. The BALLOT -- which
	options are on offer -- changes once a step. The TALLY changes every time
	anyone in the server clicks, which over fifteen seconds of a full server is
	more or less constant. Rebuilding the rows on a tally change would destroy
	and recreate the button under the player's cursor between the press and the
	release: the release then lands on an instance that no longer has a parent,
	and the vote the player thought they cast never happens. So the clones are
	rebuilt only when the CHOICE LIST changes, and updated in place otherwise.

	The other half of that: a rebuild DESTROYS the previous clones first. Clones
	merely left behind accumulate one ballot per round for the whole session --
	a leak that is also plainly visible, as a list that grows a duplicate set of
	rows every few minutes.

	WHY THE SCREEN IS BOUND IN A LOOP

	StarterGui.ResetPlayerGuiOnSpawn is on by default and re-clones the whole
	of PlayerGui on every respawn, and players die several times a round here.
	Elements resolved once would be a destroyed tree from the first death
	onwards -- and a write to a destroyed instance is a silent no-op, not an
	error, so the panel would simply stop appearing with nothing in the output
	to say why. attachLoop re-resolves them, and the "should this be showing?"
	flag is kept apart from "is anything bound?" so a ballot that opens while
	the tree is mid-replacement is still on screen when the new one lands.

	WHY YOUR CHOICE COMES OFF A LOCAL VARIABLE

	Round.Vote carries counts, never who voted for what: it is public state, and
	a public record of every player's vote is not something this panel needs. So
	the replica can say a vote landed and never that it was yours. The local
	mark is the only source of that fact, and it is presentation only -- the
	server owns the vote, re-checks that the option is on the ballot, and drops
	anything inside Config.RateLimit.Vote.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Log = require(ReplicatedStorage.Shared.Log)
local MapCatalog = require(ReplicatedStorage.Shared.MapCatalog)
local Match = require(ReplicatedStorage.Shared.Match)
local MatchController = require(script.Parent.MatchController)
local Net = require(ReplicatedStorage.Shared.Net)
local UIController = require(script.Parent.UIController)

local log = Log.new("VoteController")

local player = Players.LocalPlayer

local SCREEN_NAME = "Vote"

-- Bounded, so a place with no Vote screen authored costs one line in the
-- output rather than a Start() that never returns. Start is spawned per
-- controller (Loader.luau), so waiting here delays nothing but this panel.
local SCREEN_TIMEOUT = 10

-- The countdown is a clock, not an animation. Four ticks a second keeps a
-- whole-second readout honest to within a frame and costs nothing; a per-frame
-- rewrite of the same string would be sixty times the work for no visible
-- difference.
local TIMER_INTERVAL = 0.25

-- The progress segments: the accent for a step done or in progress, a dim
-- slate for one still to come. The accent is the UI's cyan (MainMenu, CashPill).
local STEP_ACTIVE_COLOR = Color3.fromRGB(0, 200, 255)
local STEP_PENDING_COLOR = Color3.fromRGB(44, 50, 66)

type Ballot = "Map" | "GameMode" | "TeamMode"
type Step = Ballot | "Summary"

-- The order a player is walked through. The index is the step number shown.
local BALLOT_ORDER: { Ballot } = { "Map", "GameMode", "TeamMode" }

type OptionCard = {
	root: GuiButton,
	nameLabel: TextLabel,
	taglineLabel: TextLabel,
	voteCountLabel: TextLabel,
	shareBar: GuiObject,
}

type SummaryCard = {
	root: GuiObject,
	nameLabel: TextLabel,
	countLabel: TextLabel,
}

type Elements = {
	stepLabel: TextLabel,
	titleLabel: TextLabel,
	subtitleLabel: TextLabel,
	timerLabel: TextLabel,
	-- Progress segments, in ballot order.
	segments: { GuiObject },
	options: GuiObject,
	optionTemplate: GuiButton,
	summary: GuiObject,
	summaryTemplate: GuiObject,
}

-- Round.Vote as RoundService writes it (its RoundData type is the contract).
-- Cast once, at the observer, so nothing below has to re-check the shape.
type VoteTable = {
	MapChoices: { string },
	MapVotes: { [string]: number },
	GameModeVotes: { [string]: number },
	TeamModeVotes: { [string]: number },
}

local STEP_TITLE: { [string]: string } = {
	Map = "CHOOSE A MAP",
	GameMode = "CHOOSE A GAME MODE",
	TeamMode = "CHOOSE THE TEAMS",
	Summary = "VOTES SO FAR",
}

local STEP_SUBTITLE: { [string]: string } = {
	Map = "Most votes wins. A tie breaks at random.",
	GameMode = "The rules: code length, or a faster pace.",
	TeamMode = "Two teams, four teams, or everyone for themselves.",
	Summary = "The vote closes when the timer runs out.",
}

-- What the summary row calls each ballot.
local BALLOT_KIND: { [string]: string } = {
	Map = "MAP",
	GameMode = "GAME MODE",
	TeamMode = "TEAMS",
}

--[[
	The two mode ballots, mirroring VoteService's exactly: the same Match ORDER
	lists, so every row here is an option the server accepts, and nothing the
	server accepts is missing here.
]]
local GAME_MODE_BALLOT: { string } = table.clone(Match.GAME_MODE_ORDER) :: { any }
local TEAM_MODE_BALLOT: { string } = table.clone(Match.TEAM_MODE_ORDER) :: { any }

local VoteController = {}

local screen: Elements? = nil
local isOpen = false
local step: Step = "Map"
local vote: VoteTable? = nil

local optionCards: { [string]: OptionCard } = {}
local optionOrder: { string } = {}
local optionBallot: Ballot? = nil

-- One summary row per ballot, built once per open panel.
local summaryCards: { [string]: SummaryCard } = {}

-- What THIS player picked, per ballot. See the header: the replica cannot
-- tell us.
local choices: { [string]: string } = {}

local timerConnection: RBXScriptConnection? = nil

-- Forward declared: the step advance below is written before the render it
-- triggers.
local refresh: () -> ()

local function sameList(a: { string }, b: { string }): boolean
	if #a ~= #b then
		return false
	end
	for index, value in a do
		if b[index] ~= value then
			return false
		end
	end
	return true
end

local function formatSeconds(seconds: number): string
	-- MatchController.secondsRemaining() rejects NaN before its own clamp, so
	-- this is a second guard at this file's boundary rather than the only one.
	-- It stays because NaN sails past math.max -- both comparisons are false
	-- (quality-gate.md trap #8) -- and the visible failure is a panel reading
	-- "nans" for the whole ballot, for one comparison saved.
	if seconds ~= seconds then
		seconds = 0
	end
	return `{math.max(0, math.ceil(seconds))}s`
end

--[[
	Display name and one-line tagline for a ballot entry.
]]
local function describe(ballot: Ballot, id: string): (string, string)
	if ballot == "GameMode" then
		local mode = Match.GAME_MODES[id]
		if mode == nil then
			return id, ""
		end
		return mode.DisplayName, mode.Tagline
	end
	if ballot == "TeamMode" then
		local mode = Match.TEAM_MODES[id]
		if mode == nil then
			return id, ""
		end
		return mode.DisplayName, mode.Tagline
	end

	local definition = MapCatalog.byId(id)
	if definition == nil then
		-- A ballot entry this catalog does not know means the client is a
		-- version behind the server. Draw the raw id: a blank row hides the
		-- skew, and someone has to see it to fix it.
		return id, ""
	end
	return definition.DisplayName, definition.Tagline
end

local function choicesFor(ballot: Ballot): { string }
	if ballot == "GameMode" then
		return GAME_MODE_BALLOT
	end
	if ballot == "TeamMode" then
		return TEAM_MODE_BALLOT
	end
	local current = vote
	if current == nil then
		return {}
	end
	return current.MapChoices
end

local function votesFor(ballot: Ballot): { [string]: number }?
	local current = vote
	if current == nil then
		return nil
	end
	if ballot == "GameMode" then
		return current.GameModeVotes
	end
	if ballot == "TeamMode" then
		return current.TeamModeVotes
	end
	return current.MapVotes
end

local function countOf(counts: { [string]: number }?, id: string): number
	if counts == nil then
		return 0
	end
	return counts[id] or 0
end

local function totalOf(counts: { [string]: number }?, ids: { string }): number
	local total = 0
	for _, id in ids do
		total += countOf(counts, id)
	end
	return total
end

local function votesText(count: number): string
	return if count == 1 then "1 VOTE" else `{count} VOTES`
end

local function sendVote(ballot: Ballot, id: string)
	if ballot == "Map" then
		Net.voteMap.send({ mapId = id })
	elseif ballot == "GameMode" then
		Net.voteGameMode.send({ modeId = id })
	else
		Net.voteTeamMode.send({ modeId = id })
	end
end

local function nextStep(ballot: Ballot): Step
	local index = table.find(BALLOT_ORDER, ballot)
	if index ~= nil and index < #BALLOT_ORDER then
		return BALLOT_ORDER[index + 1]
	end
	return "Summary"
end

--[[
	Pulls the authored labels out of a fresh clone.

	Returns nil rather than erroring on a template missing a label: this runs
	inside a list build, and one malformed template should cost the panel a
	warning and one row, not the whole vote screen.
]]
local function buildCard(clone: GuiButton): OptionCard?
	local nameLabel = clone:FindFirstChild("NameLabel")
	local taglineLabel = clone:FindFirstChild("TaglineLabel")
	local voteCountLabel = clone:FindFirstChild("VoteCountLabel")
	local shareBar = clone:FindFirstChild("ShareBar")

	if
		nameLabel == nil
		or not nameLabel:IsA("TextLabel")
		or taglineLabel == nil
		or not taglineLabel:IsA("TextLabel")
		or voteCountLabel == nil
		or not voteCountLabel:IsA("TextLabel")
		or shareBar == nil
		or not shareBar:IsA("GuiObject")
	then
		return nil
	end

	return {
		root = clone,
		nameLabel = nameLabel,
		taglineLabel = taglineLabel,
		voteCountLabel = voteCountLabel,
		shareBar = shareBar,
	}
end

--[[
	Destroy, never `Parent = nil`. Destroy also drops the Activated connection
	each clone holds, which is why there is no second connection list here to
	keep in step with this table.
]]
local function destroyOptionCards()
	for _, card in optionCards do
		card.root:Destroy()
	end
	table.clear(optionCards)
	table.clear(optionOrder)
	optionBallot = nil
end

local function destroySummaryCards()
	for _, card in summaryCards do
		card.root:Destroy()
	end
	table.clear(summaryCards)
end

local function onOptionActivated(ballot: Ballot, id: string)
	-- The SEND is skipped for a repeat of the choice already held --
	-- VoteService drops a re-send of an identical vote before it costs a
	-- replication packet, so there is nothing to gain by making the trip.
	if choices[ballot] ~= id then
		choices[ballot] = id
		sendVote(ballot, id)
	end

	-- Straight to the next step, on the click itself. The next step appearing
	-- IS the acknowledgement, and the summary shows every choice afterwards.
	step = nextStep(ballot)
	refresh()
end

local function syncOptions(ui: Elements, ballot: Ballot)
	local ids = choicesFor(ballot)

	if optionBallot ~= ballot or not sameList(optionOrder, ids) then
		destroyOptionCards()
		optionBallot = ballot
		--[[
			table.clone, because the list compared against next time has to be
			ours: MapChoices is replaced wholesale by the server at every
			beginVote, and holding the replica's own table would be comparing a
			list against itself and concluding nothing ever changed.
		]]
		optionOrder = table.clone(ids)

		for index, id in ids do
			-- One documented cast: Clone() is typed as returning Instance, and
			-- this is what keeps every use below typed instead of `any`.
			local clone = ui.optionTemplate:Clone() :: GuiButton
			local card = buildCard(clone)
			if card == nil then
				clone:Destroy()
				log.warn(`OptionTemplate is missing a label or its ShareBar -- the ballot cannot draw "{id}"`)
				continue
			end

			-- The id already IS the project's instance-naming convention
			-- (PascalCase, descriptive), and naming the clone after the option
			-- makes it findable in the explorer mid-playtest.
			clone.Name = id
			-- The layout sorts on LayoutOrder. By name it would put Dockyard
			-- above NeonDistrict whatever order the server actually drew, and
			-- for modes it would lose Match's ORDER lists entirely.
			clone.LayoutOrder = index
			clone.Visible = true

			local name, tagline = describe(ballot, id)
			card.nameLabel.Text = name
			card.taglineLabel.Text = tagline

			clone.Activated:Connect(function()
				onOptionActivated(ballot, id)
			end)

			clone.Parent = ui.options
			optionCards[id] = card
		end
	end

	-- Everything from here runs on every tally change and touches no
	-- instance's existence. That is the whole point of the guard above.
	local counts = votesFor(ballot)
	local total = totalOf(counts, ids)
	for id, card in optionCards do
		local count = countOf(counts, id)
		card.voteCountLabel.Text = `{count}`
		-- The share of this ballot's votes, as the width of the bar under the
		-- row. Zero votes in total draws no bar at all rather than dividing
		-- by zero into a NaN width.
		local share = if total > 0 then count / total else 0
		card.shareBar.Size = UDim2.new(share, 0, card.shareBar.Size.Y.Scale, card.shareBar.Size.Y.Offset)
	end
end

--[[
	What is winning a ballot right now: the leading option's name and its
	count, or a tie named as such. The tie is shown honestly -- "TIED" -- rather
	than as whichever of the tied options happens to sort first, because the
	server will break it at random and a row naming one of them would be a
	promise it cannot keep.
]]
local function leaderOf(ballot: Ballot): (string, string)
	local ids = choicesFor(ballot)
	local counts = votesFor(ballot)

	local best = 0
	local leaders: { string } = {}
	for _, id in ids do
		local count = countOf(counts, id)
		if count > best then
			best = count
			table.clear(leaders)
			table.insert(leaders, id)
		elseif count == best and count > 0 then
			table.insert(leaders, id)
		end
	end

	if best == 0 then
		return "NO VOTES YET", ""
	end
	if #leaders > 1 then
		local names: { string } = {}
		for _, id in leaders do
			table.insert(names, (describe(ballot, id)))
		end
		return `TIED: {table.concat(names, " / ")}`, votesText(best)
	end
	return (describe(ballot, leaders[1])), votesText(best)
end

local function syncSummary(ui: Elements)
	-- Annotated: an inferred loop value widens Ballot to `string`.
	for index, ballot: Ballot in BALLOT_ORDER do
		local card = summaryCards[ballot]
		if card == nil then
			local clone = ui.summaryTemplate:Clone() :: GuiObject
			local kindLabel = clone:FindFirstChild("KindLabel")
			local nameLabel = clone:FindFirstChild("NameLabel")
			local countLabel = clone:FindFirstChild("CountLabel")
			if
				kindLabel == nil
				or not kindLabel:IsA("TextLabel")
				or nameLabel == nil
				or not nameLabel:IsA("TextLabel")
				or countLabel == nil
				or not countLabel:IsA("TextLabel")
			then
				clone:Destroy()
				log.warn("SummaryTemplate is missing KindLabel, NameLabel or CountLabel -- the tally cannot draw")
				return
			end

			kindLabel.Text = BALLOT_KIND[ballot]
			clone.Name = `{ballot}Summary`
			clone.LayoutOrder = index
			clone.Visible = true
			clone.Parent = ui.summary

			card = { root = clone, nameLabel = nameLabel, countLabel = countLabel }
			summaryCards[ballot] = card
		end

		local name, count = leaderOf(ballot)
		card.nameLabel.Text = name
		card.countLabel.Text = count
	end
end

local function syncProgress(ui: Elements)
	-- The segment for the current ballot and every one before it lights; in
	-- the summary they all do.
	local current = if step == "Summary" then #BALLOT_ORDER + 1 else table.find(BALLOT_ORDER, step) or 1
	for index, segment in ui.segments do
		segment.BackgroundColor3 = if index <= current then STEP_ACTIVE_COLOR else STEP_PENDING_COLOR
	end
end

function refresh()
	local ui = screen
	if ui == nil or not isOpen then
		return
	end

	ui.titleLabel.Text = STEP_TITLE[step]
	ui.subtitleLabel.Text = STEP_SUBTITLE[step]
	syncProgress(ui)

	if step == "Summary" then
		ui.stepLabel.Text = "ALL VOTES CAST"
		ui.options.Visible = false
		ui.summary.Visible = true
		-- The rows belong to the step that built them. Parking them behind a
		-- hidden frame is exactly the accumulation this panel exists to avoid.
		destroyOptionCards()
		syncSummary(ui)
		return
	end

	-- Annotated: `step` is a Step here, and only a Ballot is a key below.
	local ballot: Ballot = step :: Ballot
	ui.stepLabel.Text = `STEP {table.find(BALLOT_ORDER, ballot) or 1} OF {#BALLOT_ORDER}`
	ui.options.Visible = true
	ui.summary.Visible = false
	syncOptions(ui, ballot)
end

local function stopTimer()
	local connection = timerConnection
	if connection == nil then
		return
	end
	timerConnection = nil
	connection:Disconnect()
end

local function startTimer(ui: Elements)
	stopTimer()

	-- Drawn once, immediately: a quarter second of the authored placeholder is
	-- the same first-frame lie DataController.observe exists to remove.
	ui.timerLabel.Text = formatSeconds(MatchController.secondsRemaining())

	local elapsed = 0
	timerConnection = RunService.Heartbeat:Connect(function(delta)
		elapsed += delta
		if elapsed < TIMER_INTERVAL then
			return
		end
		elapsed = 0
		ui.timerLabel.Text = formatSeconds(MatchController.secondsRemaining())
	end)
end

--[[
	The main menu's own overlays. While one is up the ballot is hidden, not
	closed: the panel is stacking, so nothing else takes it down, and it was
	drawing over the inventory, the shop and the settings. Back on the main
	menu it comes back where the player left it.
]]
local MENU_OVERLAYS = { "Inventory", "Shop", "Settings" }

local function overlayOpen(): boolean
	for _, name in MENU_OVERLAYS do
		if UIController.isOpen(name) then
			return true
		end
	end
	return false
end

--[[
	Puts the panel on screen from whatever the current step and tally are, or
	takes it off while a menu overlay is covering it.

	Separate from openVote because it has more callers than the vote opening:
	the screen being re-bound underneath a vote that was ALREADY open, and an
	overlay opening or closing. None of those may reset the step, so the local
	marks survive a hide.
]]
local function show()
	local ui = screen
	if ui == nil or not isOpen then
		-- Nothing bound yet, or the bound tree has since been re-cloned.
		-- attachLoop below calls this again once there is a panel to show.
		return
	end

	if overlayOpen() then
		-- The timer goes with the panel. A Heartbeat left counting for a
		-- screen nobody can see is the "left running off screen" the project
		-- rules name.
		stopTimer()
		if UIController.isOpen(SCREEN_NAME) then
			UIController.close(SCREEN_NAME)
		end
		return
	end

	UIController.open(SCREEN_NAME)
	startTimer(ui)
	refresh()
end

local function openVote()
	if isOpen then
		return
	end
	--[[
		Set before the screen is consulted, never after. The match does not
		wait for this client to have a panel bound -- PlayerGui is re-cloned on
		every respawn -- and a flag that only flipped when the elements
		happened to be in hand is a ballot the player never sees, silently, for
		the whole fifteen seconds.
	]]
	isOpen = true

	-- A ballot is per round. Anything carried in from the last one is a vote
	-- for a map that is no longer on offer, on a step the player never took.
	step = "Map"
	table.clear(choices)

	show()
end

local function closeVote()
	if not isOpen then
		return
	end
	isOpen = false

	-- Every handle this panel owns, released on the one path out. The
	-- Heartbeat especially: a timer still bound while the screen is gone is
	-- the "left running off screen" the project rules name.
	stopTimer()
	destroyOptionCards()
	destroySummaryCards()

	-- UIController.isOpen is false for a screen this build never authored, and
	-- for one whose tree has just been re-cloned out from under us, so asking
	-- it first is what keeps UIController quiet about both cases rather than
	-- warning on every close (MenuController.closeIfOpen).
	if UIController.isOpen(SCREEN_NAME) then
		UIController.close(SCREEN_NAME)
	end
end

local function applyState(state: Match.MatchState)
	if state == "Voting" then
		openVote()
	else
		closeVote()
	end
end

function VoteController.Init()
	--[[
		Nothing registers here, and that is a decision rather than an omission.
		This controller listens to no packet and owns no replica -- the round
		replica is MatchController's -- and MatchController.observe fires with
		the current value the moment it is registered. So nothing below can
		miss an event that arrived before Start(), which is the only reason a
		listener would have to live in Init().
	]]
end

--[[
	Finds this screen's authored elements, or nil if any of them is missing.

	Everything under the ScreenGui arrived with it: PlayerGui is filled by a
	local clone of StarterGui, so the subtree lands as a unit. UIController
	reads a screen's children the same way, on the same reasoning -- which is
	why there is no WaitForChild below this point.
]]
local function resolve(gui: Instance): Elements?
	local root = gui:FindFirstChild("Root")
	if root == nil then
		log.warn(`{SCREEN_NAME} has no Root -- the vote panel will not be drawn`)
		return nil
	end

	local function grab(path: string, className: string): Instance?
		local current: Instance? = root
		for segment in string.gmatch(path, "[^%.]+") do
			if current == nil then
				break
			end
			current = current:FindFirstChild(segment)
		end

		if current == nil then
			log.warn(`{SCREEN_NAME}.Root.{path} is missing -- the vote panel will not be drawn`)
			return nil
		end
		if not current:IsA(className) then
			log.warn(`{SCREEN_NAME}.Root.{path} should be a {className}, not a {current.ClassName}`)
			return nil
		end
		return current
	end

	local stepLabel = grab("Panel.Header.StepLabel", "TextLabel") :: TextLabel?
	local titleLabel = grab("Panel.Header.TitleLabel", "TextLabel") :: TextLabel?
	local subtitleLabel = grab("Panel.Header.SubtitleLabel", "TextLabel") :: TextLabel?
	local timerLabel = grab("Panel.Header.TimerLabel", "TextLabel") :: TextLabel?
	local options = grab("Panel.Options", "GuiObject") :: GuiObject?
	-- A GuiButton, not a GuiObject: a ballot whose rows cannot be clicked is
	-- not a degraded vote panel, it is a vote nobody can cast.
	local optionTemplate = grab("Panel.OptionTemplate", "GuiButton") :: GuiButton?
	local summary = grab("Panel.Summary", "GuiObject") :: GuiObject?
	local summaryTemplate = grab("Panel.SummaryTemplate", "GuiObject") :: GuiObject?

	-- One segment per ballot, Step1..StepN, in order.
	local segments: { GuiObject } = {}
	for index = 1, #BALLOT_ORDER do
		local segment = grab(`Panel.Progress.Step{index}`, "GuiObject") :: GuiObject?
		if segment == nil then
			return nil
		end
		table.insert(segments, segment)
	end

	if
		stepLabel == nil
		or titleLabel == nil
		or subtitleLabel == nil
		or timerLabel == nil
		or options == nil
		or optionTemplate == nil
		or summary == nil
		or summaryTemplate == nil
	then
		-- grab() already named every element it could not find. An incomplete
		-- screen is a Studio authoring slip, not a reason to error a boot.
		return nil
	end

	-- The templates sit beside their containers rather than inside them, so an
	-- author who left one visible would ship a permanent extra row. Hidden
	-- here rather than relied upon to have been hidden there.
	optionTemplate.Visible = false
	summaryTemplate.Visible = false

	return {
		stepLabel = stepLabel,
		titleLabel = titleLabel,
		subtitleLabel = subtitleLabel,
		timerLabel = timerLabel,
		segments = segments,
		options = options,
		optionTemplate = optionTemplate,
		summary = summary,
		summaryTemplate = summaryTemplate,
	}
end

--[[
	Drops every reference to a tree that is on its way out.

	The clones are NOT destroyed here. They are children of that tree and go
	with it, so the only thing that would survive this function is the TABLES
	naming them -- and a table still naming a corpse is exactly what would make
	the next attach believe the ballot had already been drawn and skip the
	rebuild. The Heartbeat is stopped because it is ours and outlives any
	instance.

	isOpen is deliberately untouched: the match does not pause for a respawn,
	so "this panel should be showing" is still true and attachLoop acts on it
	as soon as there is somewhere to show it.
]]
local function detach()
	screen = nil
	stopTimer()

	table.clear(optionCards)
	table.clear(optionOrder)
	optionBallot = nil
	table.clear(summaryCards)
end

--[[
	Binds the panel, and re-binds it for the rest of the session.

	StarterGui.ResetPlayerGuiOnSpawn is on by default and wipes PlayerGui on
	EVERY respawn, and in this game a player dies several times a round. A
	controller that resolved its elements once would therefore be writing into
	a destroyed tree from the first death onwards -- silently, because a write
	to a destroyed instance is a no-op and not an error -- and the vote panel
	would never appear again for the whole session, which is the one screen
	where that failure costs the player the round that follows. HUDController
	re-binds for exactly this reason and UIController re-registers the
	replacement screen for it too.
]]
local function attachLoop()
	local playerGui = player:WaitForChild("PlayerGui")

	while true do
		-- WaitForChild, not an index: StarterGui is copied into PlayerGui when
		-- the character spawns, which is well after every Start() has begun. A
		-- direct index is a race that happens to pass on a fast machine.
		local screensFolder = playerGui:WaitForChild("Screens", SCREEN_TIMEOUT)
		if screensFolder == nil then
			log.info("no PlayerGui.Screens folder -- nothing to drive")
			return
		end

		local gui = screensFolder:WaitForChild(SCREEN_NAME, SCREEN_TIMEOUT)
		if gui == nil then
			log.info(`no Screens.{SCREEN_NAME} authored yet -- nothing to drive`)
			return
		end

		screen = resolve(gui)
		if isOpen then
			--[[
				A ballot that was already running when the tree was replaced.
				The re-clone reset every screen to its authored Enabled state,
				so the panel has to be asked for again -- but the step and the
				local marks survive on purpose: the vote did not restart, only
				the instances did.
			]]
			show()
		end

		screensFolder.Destroying:Wait()
		detach()

		--[[
			Destroying fires while the folder is still parented, so an
			immediate WaitForChild("Screens") can be handed back the very
			instance that is on its way out -- and the next pass would then
			bind to a corpse and spend the whole timeout waiting for a child
			that can never arrive (MenuController.attachLoop makes the same
			point).
		]]
		while playerGui:FindFirstChild("Screens") == screensFolder do
			playerGui.ChildRemoved:Wait()
		end
	end
end

function VoteController.Start()
	--[[
		Observers FIRST, the screen second, and that order is load-bearing:
		binding yields on WaitForChild, and a vote that opened during that wait
		must still be recorded. openVote sets isOpen whether or not there is a
		panel yet, and attachLoop shows it the moment there is.

		observe, not onStateChanged. onStateChanged fires on a CHANGE, and a
		player who joins a server already mid-vote never sees one -- this
		Start() runs long after MatchController took the replica's first state,
		so a change-only listener would leave the panel shut for an entire
		ballot the player was entitled to vote in. observe fires with the
		current value the moment it is registered AND on every change after,
		which is the same late-joiner argument DataController.observe is built
		on.

		Vote is registered before State because both fire synchronously when
		the replica has already landed: opening the panel before the ballot is
		in hand would draw one frame of empty list.
	]]
	MatchController.observe({ "Vote" }, function(value: any)
		-- The one cast, at the boundary. RoundService is the sole writer of
		-- this table and its RoundData type is the contract; below this line
		-- the shape is taken as read.
		vote = if type(value) == "table" then value :: VoteTable else nil
		refresh()
	end)

	MatchController.observe({ "State" }, function(value: any)
		-- A replicated field is a promise nobody kept. Match.isState is the
		-- guard the rest of the codebase already uses on exactly this value.
		if not Match.isState(value) then
			return
		end
		applyState(value :: Match.MatchState)
	end)

	--[[
		Deferred, not called inline. Going from one overlay straight to another
		closes the first before the second counts as open (UIController.open
		hides the outgoing exclusive screen first), so asking in the same frame
		would flash the ballot for one frame between them. A frame later the
		swap has settled.
	]]
	local function onOverlayChanged()
		task.defer(show)
	end
	for _, name in MENU_OVERLAYS do
		UIController.onOpen(name, onOverlayChanged)
		UIController.onClose(name, onOverlayChanged)
	end

	attachLoop()
end

return VoteController
