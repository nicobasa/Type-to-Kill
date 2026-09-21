--!strict
--[[
	The fifteen-second ballot, drawn client side: pick a map, pick a mode, then
	watch the tally.

	The screen is authored in Studio and only found here (ARCHITECTURE.md, "The
	map"). The one thing this file creates is clones of the authored
	OptionTemplate and RowTemplate, which exist for exactly that.

	WHY THE REBUILD IS GUARDED

	Two things move this panel, at very different rates. The BALLOT -- which
	maps are on offer -- changes once a round. The TALLY changes every time
	anyone in the server clicks, which over fifteen seconds of a full server is
	more or less constant. Rebuilding the cards on a tally change would destroy
	and recreate the button under the player's cursor between the press and the
	release: the release then lands on an instance that no longer has a parent,
	and the vote the player thought they cast never happens. So the clones are
	rebuilt only when the CHOICE LIST changes, and updated in place otherwise.

	The other half of that: a rebuild DESTROYS the previous clones first. Clones
	merely left behind accumulate one ballot per round for the whole session --
	a leak that is also plainly visible, as a list that grows a duplicate set of
	cards every few minutes.

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

local Config = require(ReplicatedStorage.Shared.Config)
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

type Ballot = "Map" | "Mode"
type Step = "Map" | "Mode" | "Summary"

type OptionCard = {
	root: GuiButton,
	nameLabel: TextLabel,
	taglineLabel: TextLabel,
	voteCountLabel: TextLabel,
}

type RowCard = {
	root: GuiObject,
	countLabel: TextLabel,
}

--[[
	The clones of one summary column, plus the id list they were built from.
	Keeping the list is what makes "did the ballot change?" answerable without
	touching a single instance.
]]
type RowState = {
	clones: { [string]: RowCard },
	order: { string },
}

--[[
	The column HeaderLabels are deliberately absent: they are written once, as
	the tree is resolved, and never read again. A field nothing reads is a
	field the next reader has to prove nothing reads.
]]
type Elements = {
	titleLabel: TextLabel,
	subtitleLabel: TextLabel,
	timerLabel: TextLabel,
	options: GuiObject,
	optionTemplate: GuiButton,
	summary: GuiObject,
	mapRows: GuiObject,
	modeRows: GuiObject,
	rowTemplate: GuiObject,
}

-- Round.Vote as RoundService writes it (its RoundData type is the contract).
-- Cast once, at the observer, so nothing below has to re-check the shape.
type VoteTable = {
	MapChoices: { string },
	MapVotes: { [string]: number },
	ModeVotes: { [string]: number },
}

local STEP_TITLE: { [string]: string } = {
	Map = "CHOOSE A MAP",
	Mode = "CHOOSE A MODE",
	Summary = "VOTES SO FAR",
}

local STEP_SUBTITLE: { [string]: string } = {
	Map = "Most votes wins. A tie breaks at random.",
	Mode = "Most votes wins. A tie breaks at random.",
	Summary = "The ballot closes when the timer runs out.",
}

--[[
	The mode ballot, mirroring VoteService's exactly.

	The server builds its own from Match.MODE_ORDER capped at
	Config.Voting.MaxModeChoices, and drops a vote for anything past the cap --
	so a card drawn past it would be a button that silently does nothing. The
	cap belongs on both sides or on neither.
]]
local MODE_BALLOT: { string } = {}
for index = 1, math.min(Config.Voting.MaxModeChoices, #Match.MODE_ORDER) do
	table.insert(MODE_BALLOT, Match.MODE_ORDER[index])
end

local VoteController = {}

local screen: Elements? = nil
local isOpen = false
local step: Step = "Map"
local vote: VoteTable? = nil

local optionCards: { [string]: OptionCard } = {}
local optionOrder: { string } = {}
local optionBallot: Ballot? = nil

local mapRowState: RowState = { clones = {}, order = {} }
local modeRowState: RowState = { clones = {}, order = {} }

-- What THIS player picked. See the header: the replica cannot tell us.
local mapChoice: string? = nil
local modeChoice: string? = nil

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
	if ballot == "Mode" then
		local mode = Match.MODES[id]
		if mode == nil then
			return id, ""
		end
		--[[
			A GameMode has no Tagline field and should not grow one for this
			panel: the only thing that actually differs between the two modes
			is whether there are teams, and that is already a field. Prose
			invented here would be a third place to keep mode copy.
		]]
		return mode.DisplayName, if mode.UsesTeams then "Two teams" else "Everyone for themselves"
	end

	local definition = MapCatalog.byId(id)
	if definition == nil then
		-- A ballot entry this catalog does not know means the client is a
		-- version behind the server. Draw the raw id: a blank card hides the
		-- skew, and someone has to see it to fix it.
		return id, ""
	end
	return definition.DisplayName, definition.Tagline
end

local function choicesFor(ballot: Ballot): { string }
	if ballot == "Mode" then
		return MODE_BALLOT
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
	return if ballot == "Map" then current.MapVotes else current.ModeVotes
end

local function chosenFor(ballot: Ballot): string?
	return if ballot == "Map" then mapChoice else modeChoice
end

local function countOf(counts: { [string]: number }?, id: string): number
	if counts == nil then
		return 0
	end
	return counts[id] or 0
end

--[[
	Pulls the authored labels out of a fresh clone.

	Returns nil rather than erroring on a template missing a label: this runs
	inside a list build, and one malformed template should cost the panel a
	warning and one card, not the whole vote screen.
]]
local function buildCard(clone: GuiButton): OptionCard?
	local nameLabel = clone:FindFirstChild("NameLabel")
	local taglineLabel = clone:FindFirstChild("TaglineLabel")
	local voteCountLabel = clone:FindFirstChild("VoteCountLabel")

	if
		nameLabel == nil
		or not nameLabel:IsA("TextLabel")
		or taglineLabel == nil
		or not taglineLabel:IsA("TextLabel")
		or voteCountLabel == nil
		or not voteCountLabel:IsA("TextLabel")
	then
		return nil
	end

	return {
		root = clone,
		nameLabel = nameLabel,
		taglineLabel = taglineLabel,
		voteCountLabel = voteCountLabel,
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

local function destroyRows(state: RowState)
	for _, card in state.clones do
		card.root:Destroy()
	end
	table.clear(state.clones)
	table.clear(state.order)
end

local function onOptionActivated(ballot: Ballot, id: string)
	-- The SEND is skipped for a repeat of the choice already held --
	-- VoteService drops a re-send of an identical vote before it costs a
	-- replication packet, so there is nothing to gain by making the trip.
	if chosenFor(ballot) ~= id then
		if ballot == "Map" then
			mapChoice = id
			Net.voteMap.send({ mapId = id })
		else
			modeChoice = id
			Net.voteMode.send({ modeId = id })
		end
	end

	--[[
		Straight to the next step, on the click itself. There used to be a
		0.45s beat here, and a YOUR VOTE badge on the chosen card to fill it;
		players read the pause as lag between the two ballots, so both went.
		The next step appearing IS the acknowledgement, and the Summary step
		shows both choices afterwards.
	]]
	step = if ballot == "Map" then "Mode" else "Summary"
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
				log.warn(`OptionTemplate is missing a label -- the ballot cannot draw "{id}"`)
				continue
			end

			-- The id already IS the project's instance-naming convention
			-- (PascalCase, descriptive), and naming the clone after the option
			-- makes it findable in the explorer mid-playtest.
			clone.Name = id
			-- The layout sorts on LayoutOrder. By name it would put Dockyard
			-- above NeonDistrict whatever order the server actually drew, and
			-- for modes it would lose Match.MODE_ORDER entirely.
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
	for id, card in optionCards do
		-- The bare number, not "3 VOTES": VoteCountLabel is authored as a small
		-- badge sized for a digit, and the card around it already says what is
		-- being counted.
		card.voteCountLabel.Text = `{countOf(counts, id)}`
	end
end

local function syncRows(ui: Elements, container: GuiObject, state: RowState, ballot: Ballot)
	local ids = choicesFor(ballot)

	if not sameList(state.order, ids) then
		destroyRows(state)
		state.order = table.clone(ids)

		for index, id in ids do
			local clone = ui.rowTemplate:Clone() :: GuiObject
			local nameLabel = clone:FindFirstChild("NameLabel")
			local countLabel = clone:FindFirstChild("CountLabel")
			if
				nameLabel == nil
				or not nameLabel:IsA("TextLabel")
				or countLabel == nil
				or not countLabel:IsA("TextLabel")
			then
				clone:Destroy()
				log.warn(`RowTemplate is missing NameLabel or CountLabel -- the tally cannot draw "{id}"`)
				continue
			end

			local name = describe(ballot, id)
			nameLabel.Text = name

			clone.Name = id
			clone.LayoutOrder = index
			clone.Visible = true
			clone.Parent = container

			state.clones[id] = { root = clone, countLabel = countLabel }
		end
	end

	local counts = votesFor(ballot)
	for id, card in state.clones do
		card.countLabel.Text = `{countOf(counts, id)}`
	end
end

function refresh()
	local ui = screen
	if ui == nil or not isOpen then
		return
	end

	ui.titleLabel.Text = STEP_TITLE[step]
	ui.subtitleLabel.Text = STEP_SUBTITLE[step]

	local ballot: Ballot? = if step == "Map" then "Map" elseif step == "Mode" then "Mode" else nil

	ui.options.Visible = ballot ~= nil
	ui.summary.Visible = ballot == nil

	if ballot ~= nil then
		syncOptions(ui, ballot)
		return
	end

	-- The cards belong to the step that built them. Parking them behind a
	-- hidden frame is exactly the accumulation this panel exists to avoid.
	destroyOptionCards()
	syncRows(ui, ui.mapRows, mapRowState, "Map")
	syncRows(ui, ui.modeRows, modeRowState, "Mode")
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
	mapChoice = nil
	modeChoice = nil

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
	destroyRows(mapRowState)
	destroyRows(modeRowState)

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

	local titleLabel = grab("Panel.Header.TitleLabel", "TextLabel") :: TextLabel?
	local subtitleLabel = grab("Panel.Header.SubtitleLabel", "TextLabel") :: TextLabel?
	local timerLabel = grab("Panel.TimerLabel", "TextLabel") :: TextLabel?
	local options = grab("Panel.Options", "GuiObject") :: GuiObject?
	-- A GuiButton, not a GuiObject: a ballot whose cards cannot be clicked is
	-- not a degraded vote panel, it is a vote nobody can cast.
	local optionTemplate = grab("Panel.OptionTemplate", "GuiButton") :: GuiButton?
	local summary = grab("Panel.Summary", "GuiObject") :: GuiObject?
	local mapHeaderLabel = grab("Panel.Summary.MapColumn.HeaderLabel", "TextLabel") :: TextLabel?
	local mapRows = grab("Panel.Summary.MapColumn.Rows", "GuiObject") :: GuiObject?
	local modeHeaderLabel = grab("Panel.Summary.ModeColumn.HeaderLabel", "TextLabel") :: TextLabel?
	local modeRows = grab("Panel.Summary.ModeColumn.Rows", "GuiObject") :: GuiObject?
	local rowTemplate = grab("Panel.RowTemplate", "GuiObject") :: GuiObject?

	if
		titleLabel == nil
		or subtitleLabel == nil
		or timerLabel == nil
		or options == nil
		or optionTemplate == nil
		or summary == nil
		or mapHeaderLabel == nil
		or mapRows == nil
		or modeHeaderLabel == nil
		or modeRows == nil
		or rowTemplate == nil
	then
		-- grab() already named every element it could not find. An incomplete
		-- screen is a Studio authoring slip, not a reason to error a boot.
		return nil
	end

	-- The templates sit beside their containers rather than inside them, so an
	-- author who left one visible would ship a permanent extra card. Hidden
	-- here rather than relied upon to have been hidden there.
	optionTemplate.Visible = false
	rowTemplate.Visible = false

	-- The column headers never change. Written once per tree, so the panel
	-- never shows whatever placeholder the layout was authored with.
	mapHeaderLabel.Text = "MAP"
	modeHeaderLabel.Text = "MODE"

	return {
		titleLabel = titleLabel,
		subtitleLabel = subtitleLabel,
		timerLabel = timerLabel,
		options = options,
		optionTemplate = optionTemplate,
		summary = summary,
		mapRows = mapRows,
		modeRows = modeRows,
		rowTemplate = rowTemplate,
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

	table.clear(mapRowState.clones)
	table.clear(mapRowState.order)
	table.clear(modeRowState.clones)
	table.clear(modeRowState.order)
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
