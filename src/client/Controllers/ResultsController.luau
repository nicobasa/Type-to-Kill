--!strict
--[[
	The end-of-round screen: who won, and what you were paid.

	TWO SOURCES, AND THE SPLIT IS DELIBERATE

	The HEADLINE comes from the round replica -- the team scores and the
	scoreboard rows every client already agrees on. The RECEIPT comes from
	Net.rewardSummary, which is personal and is only sent to players who were
	actually in the round. Neither could do the other's job: a headline drawn
	from the packet would leave a spectator (and anyone whose packet was
	dropped) staring at a blank panel, and a receipt derived from the replica
	would be a guess, because what a player was granted depends on grants that
	can legitimately fail and come back as zero (RewardService, "WHY awardKill
	RETURNS AMOUNTS INSTEAD OF A BOOLEAN").

	They complement rather than duplicate: the replica says "RED TEAM WINS",
	the receipt's bonus line says "VICTORY" or "DEFEAT", and between them the
	player learns what happened in the match and what it meant for them.

	THE PODIUM IS A SNAPSHOT, NOT A LIVE VIEW

	It is built once, from the state write that opens this screen. Replica
	writes are delivered in order, so every kill that decided the round landed
	before that write -- there is nothing still in flight to wait for. A live
	rebuild would instead re-sort a table whose rows are being deleted as
	players leave, which is exactly how a podium reorders itself under the eyes
	of someone reading it.

	THE ORDER IS TOTAL, AND IT IS THE SERVER'S ORDER

	Kills desc, deaths asc, LastKillAt asc, UserId asc -- ScoreService.byRank,
	clause for clause. Copied rather than approximated for two reasons.
	table.sort is not stable and Round.Players is a dictionary whose iteration
	order Luau does not fix, so anything short of a total order lets two
	players on identical numbers swap places between two builds. And the server
	paid its rewards off ITS ranking, so a client that ranked differently would
	print a podium that disagrees with the receipt directly underneath it.

	This controller never builds a screen. Results is authored in Studio and
	found here -- and RE-found for the rest of the session, because
	StarterGui.ResetPlayerGuiOnSpawn re-clones PlayerGui on every respawn and a
	one-shot bind would stop driving the screen from the player's first death
	onwards (attachLoop). The only instances it creates are clones of the two
	authored templates, and every one of them is destroyed when the screen
	closes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Match = require(ReplicatedStorage.Shared.Match)
local MatchController = require(script.Parent.MatchController)
local Net = require(ReplicatedStorage.Shared.Net)
local UIController = require(script.Parent.UIController)

local log = Log.new("ResultsController")

local player = Players.LocalPlayer

local SCREEN_NAME = "Results"

--[[
	One budget for the WHOLE search, not one per WaitForChild. Two waits stack,
	and a timeout per call turns "Results was never authored" into twice the
	wait before the honest answer -- which was available after ten seconds
	(TeamSelectController makes the same point).
]]
local BIND_TIMEOUT = 10

-- My row in Round.Players. Constant for the session; a UserId never changes.
local SELF_KEY = Match.playerKey(player.UserId)

--[[
	The podium is three rows by construction, so the places are spelled out
	rather than computed. RewardService needs a real ordinal() because Free For
	All pays down to eleventh and "11ST" is the bug every suffix table has;
	three literals cannot have that bug, and the length of this list is also
	what bounds the loop below.
]]
local PLACE_LABELS = { "1ST", "2ND", "3RD" }

--[[
	How long the row clones outlive a close.

	Destroying them in the same frame as the close leaves an empty panel fading
	out -- UIController's exit is a tween ("snappy", 0.16s), not a cut, and the
	player is still looking at the screen for all of it. Comfortably longer than
	that tween, and cancelled outright if the screen reopens first, so no clone
	can ever survive into a round it did not belong to.
]]
local CLONE_LIFETIME_AFTER_CLOSE = 0.5

--[[
	One row of the podium, normalised out of the replica. Every field is
	re-read and re-checked rather than trusted: Match.RoundPlayer describes what
	RoundService writes, but this is a replicated table and its static type is a
	promise made on another machine.
]]
type Standing = {
	key: string,
	userId: number,
	displayName: string,
	kills: number,
	deaths: number,
	lastKillAt: number,
}

type RewardEntry = {
	label: string,
	cash: number,
	experience: number,
}

--[[
	Net.rewardSummary, as received.

	`resultText` is deliberately not drawn anywhere. RewardService already uses
	that exact string as the label of the bonus line inside `entries`, so
	printing it as a headline as well would put two answers to one question on
	the same panel -- and the headline above has to say what happened in the
	MATCH, which is not the same sentence for the winner and the loser reading
	their own copies of this screen.
]]
type Summary = {
	resultText: string,
	entries: { RewardEntry },
	totalCash: number,
	totalExperience: number,
}

--[[
	The authored elements, re-found at every bind. All optional but the panel
	itself: a half-authored screen should cost the developer a line of output
	and the player one missing label, never an error that takes the rest of the
	bind with it.
]]
type View = {
	outcomeLabel: TextLabel?,
	scoreLabel: TextLabel?,
	standings: GuiObject?,
	placeTemplate: GuiObject?,
	rewards: GuiObject?,
	rewardEntries: GuiObject?,
	rewardTemplate: GuiObject?,
	totalCashLabel: TextLabel?,
	totalExperienceLabel: TextLabel?,
}

local view: View? = nil

local podiumClones: { GuiObject } = {}
local rewardClones: { GuiObject } = {}
local clearThread: thread? = nil

local summary: Summary? = nil

--[[
	Whether WE opened the screen, which is not the same question as whether the
	screen is open -- and the distinction is what stops the catch-up apply that
	follows a bind from discarding a receipt that arrived before the state write
	did.
]]
local opened = false

local ResultsController = {}

local function remaining(deadline: number): number
	return math.max(deadline - os.clock(), 0)
end

--[[
	The Results ScreenGui, or nil if it has not arrived inside the budget.

	Three lookups, none of them redundant. Subfolders under Screens are legal
	and are organisation only -- Screens/Menus/Results is still just "Results"
	(UIController.considerChild) -- so the recursive search finds one that has
	already replicated without spending any budget; the WaitForChild covers one
	that has not arrived yet; and the second recursive search covers a subfolder
	that arrived during the wait.
]]
local function findScreen(playerGui: Instance, deadline: number): ScreenGui?
	local screens = playerGui:WaitForChild("Screens", remaining(deadline))
	if screens == nil then
		return nil
	end

	local found = screens:FindFirstChild(SCREEN_NAME, true)
	if found == nil then
		found = screens:WaitForChild(SCREEN_NAME, remaining(deadline))
	end
	if found == nil then
		found = screens:FindFirstChild(SCREEN_NAME, true)
	end

	--[[
		A non-ScreenGui named "Results" is not the screen: UIController only
		registers ScreenGuis, so driving it would leave open() and close()
		warning "no such screen" five times a round at something this
		controller had already decided to believe in.
	]]
	if found == nil or not found:IsA("ScreenGui") then
		return nil
	end
	return found
end

--[[
	A missing element is reported on the FIRST bind only.

	attachLoop re-binds on every respawn, and the tree it re-binds to is the
	same authored copy of StarterGui every time -- so a name that is wrong is
	wrong identically on each of them. Reported once it is a bug report;
	reported every few seconds for the rest of the session it is noise that
	buries whatever else was in the log. Set by attachLoop once a bind lands.
]]
local reportedMissing = false

local function reportMissing(message: string)
	if reportedMissing then
		return
	end
	log.warn(message)
end

local function findLabel(parent: Instance, name: string): TextLabel?
	local child = parent:FindFirstChild(name)
	if child == nil or not child:IsA("TextLabel") then
		reportMissing(`{parent:GetFullName()} has no {name} TextLabel -- that line stays as authored`)
		return nil
	end
	return child
end

local function findGuiObject(parent: Instance, name: string): GuiObject?
	local child = parent:FindFirstChild(name)
	if child == nil or not child:IsA("GuiObject") then
		reportMissing(`{parent:GetFullName()} has no {name} GuiObject -- that part of the screen stays as authored`)
		return nil
	end
	return child
end

--[[
	Checked at bind rather than per clone. A template child that is missing is
	missing for every row cloned from it, so warning at the clone site would
	print the same line three times a round for as long as the server lives.
]]
local function checkTemplateLabels(template: GuiObject, names: { string })
	for _, name in names do
		local child = template:FindFirstChild(name)
		if child == nil or not child:IsA("TextLabel") then
			reportMissing(
				`{template:GetFullName()} has no {name} TextLabel -- that line is left as authored on every row`
			)
		end
	end
end

--[[
	NaN is rejected as well as a non-number, and not only out of habit: every
	comparison against NaN is false, so a single NaN kill count would make the
	comparator below inconsistent and table.sort raises "invalid order function"
	on one (quality-gate.md trap #8).
]]
local function numberOr(value: any, fallback: number): number
	if type(value) ~= "number" or value ~= value then
		return fallback
	end
	return value
end

local function readScore(scores: any, team: Match.TeamId): number
	if type(scores) ~= "table" then
		return 0 -- the replica has not landed, or the round never wrote scores
	end
	return numberOr(scores[team], 0)
end

--[[
	The word carries the result, never the colour alone -- the same rule every
	team-coloured element in this game follows, and Match.TEAMS is the one place
	that spells RED and BLUE (Match.luau, TeamDefinition.Color).
]]
local function teamWinsText(team: Match.TeamId): string
	return `{Match.TEAMS[team].DisplayName} TEAM WINS`
end

local function killsText(kills: number): string
	return if kills == 1 then "1 KILL" else `{kills} KILLS`
end

--[[
	ScoreService.byRank, clause for clause. The last two clauses are what make
	it a TOTAL order, and both are load-bearing: LastKillAt asc is the design's
	own tiebreak (whoever reached the count first won it), and the UserId is the
	key that cannot repeat, so two players on identical numbers have exactly one
	legal order rather than whichever one this call happened to produce.
]]
local function byRank(a: Standing, b: Standing): boolean
	if a.kills ~= b.kills then
		return a.kills > b.kills
	end
	if a.deaths ~= b.deaths then
		return a.deaths < b.deaths
	end
	if a.lastKillAt ~= b.lastKillAt then
		return a.lastKillAt < b.lastKillAt
	end
	if a.userId ~= b.userId then
		return a.userId < b.userId
	end
	-- Only reachable if a key ever failed to yield a UserId. Comparing the keys
	-- themselves keeps the order total anyway, which is all table.sort needs.
	return a.key < b.key
end

local function collectStandings(): { Standing }
	local standings: { Standing } = {}

	local round = MatchController.getRound()
	if round == nil or type(round.Players) ~= "table" then
		return standings
	end

	for key, entry in round.Players do
		if type(key) ~= "string" or type(entry) ~= "table" then
			continue
		end

		--[[
			Only the players the SERVER ranked. Round.Players holds a row for
			everyone who has one, including players sitting in the menu with
			Team = "" (TeamSelectController counts those too), while
			ScoreService.getStandings lists only ParticipantService.isInRound --
			Playing or Killcam. Include the menu rows and every podium place
			shifts down by however many people happened to be idling in the
			lobby, and the screen then contradicts the rewards the server
			already paid. Phases are not reset until the match reaches Lobby,
			so they still read Playing/Killcam for the whole of RoundResults.
		]]
		local phase = entry.Phase
		if phase ~= "Playing" and phase ~= "Killcam" then
			continue
		end

		--[[
			The UserId is recovered from the key rather than carried as a
			field: Match.playerKey builds it as "U" plus the id precisely so it
			can never coerce back to a number by accident (Match.luau), which
			leaves the digits sitting there for the one caller that genuinely
			wants them. No extra field on the wire, and no lookup of a Player
			who may already have left the server.
		]]
		table.insert(standings, {
			key = key,
			userId = numberOr(tonumber(string.sub(key, 2)), 0),
			displayName = if type(entry.DisplayName) == "string" then entry.DisplayName else "PLAYER",
			kills = numberOr(entry.Kills, 0),
			deaths = numberOr(entry.Deaths, 0),
			lastKillAt = numberOr(entry.LastKillAt, 0),
		})
	end

	table.sort(standings, byRank)
	return standings
end

local function destroyList(clones: { GuiObject })
	for _, clone in clones do
		clone:Destroy()
	end
	table.clear(clones)
end

local function cancelScheduledClear()
	if clearThread == nil then
		return
	end
	task.cancel(clearThread)
	clearThread = nil
end

local function scheduleClear()
	cancelScheduledClear()
	clearThread = task.delay(CLONE_LIFETIME_AFTER_CLOSE, function()
		clearThread = nil
		destroyList(podiumClones)
		destroyList(rewardClones)
	end)
end

--[[
	Clones are NAMED and ordered, never left as "PlaceTemplate" x3. An authored
	UIListLayout sorting by Name would have nothing to sort three identical
	names by, so the podium would come out in whatever order the layout felt
	like -- the same class of bug the explicit sort above exists to prevent, one
	layer further down.
]]
local function cloneRow(
	template: GuiObject,
	parent: GuiObject,
	name: string,
	order: number,
	into: { GuiObject }
): GuiObject
	local row = template:Clone()
	row.Name = name
	row.LayoutOrder = order
	row.Visible = true
	row.Parent = parent
	table.insert(into, row)
	return row
end

-- Silent on a missing child: checkTemplateLabels already said so once, at bind.
local function setText(row: GuiObject, name: string, text: string)
	local label = row:FindFirstChild(name)
	if label ~= nil and label:IsA("TextLabel") then
		label.Text = text
	end
end

local function applyHeadline(current: View, standings: { Standing })
	local outcome: string
	local score: string

	if MatchController.usesTeams() then
		local round = MatchController.getRound()
		local scores = if round ~= nil then round.Scores else nil
		local red = readScore(scores, "Red")
		local blue = readScore(scores, "Blue")

		if red > blue then
			outcome = teamWinsText("Red")
		elseif blue > red then
			outcome = teamWinsText("Blue")
		else
			outcome = "DRAW"
		end
		score = `{red} - {blue}`
	else
		local leader = standings[1]
		if leader == nil then
			--[[
				Nobody was left in the round when it ended -- everyone dropped
				out, or the client's replica never arrived. A neutral line
				rather than a blank label, because a results screen that shows
				nothing at all reads as broken.
			]]
			outcome = "ROUND OVER"
			score = ""
		else
			-- The winner named, to mirror the team headline. Which place the
			-- reader took is the receipt's job, not the headline's.
			outcome = `{leader.displayName} WINS`
			score = killsText(leader.kills)
		end
	end

	local outcomeLabel = current.outcomeLabel
	if outcomeLabel ~= nil then
		outcomeLabel.Text = outcome
	end

	local scoreLabel = current.scoreLabel
	if scoreLabel ~= nil then
		scoreLabel.Text = score
	end
end

local function buildPodium(current: View, standings: { Standing })
	local list = current.standings
	if list == nil then
		return
	end

	--[[
		Hidden in Team Deathmatch, not emptied. The two team totals ARE the
		result there, and a list of individuals underneath them invites reading
		a team round as a personal ranking it is not -- while an emptied
		container still costs whatever padding the layout was authored with.
	]]
	if MatchController.usesTeams() then
		list.Visible = false
		return
	end
	list.Visible = true

	local template = current.placeTemplate
	if template == nil then
		return
	end

	for place = 1, math.min(#PLACE_LABELS, #standings) do
		local standing = standings[place]
		local row = cloneRow(template, list, `Place{place}`, place, podiumClones)

		setText(row, "PlaceLabel", PLACE_LABELS[place])
		-- Marked in words. Finding yourself on the podium is the one thing a
		-- player looks for here, and a highlight colour alone does not answer it
		-- for everyone who reads this screen.
		local name = if standing.key == SELF_KEY then `{standing.displayName} (YOU)` else standing.displayName
		setText(row, "NameLabel", name)
		setText(row, "StatsLabel", `{standing.kills} KILLS / {standing.deaths} DEATHS`)
	end
end

--[[
	No thousands grouping, deliberately. A match pays a kill tier plus one
	placement tier, which is three digits at today's Config and cannot reach
	four without a balance change -- so a separator here would be a second copy
	of PlayerCardController's formatter maintained for numbers that never need
	it. If the tiers ever grow, that formatter is the thing to share.
]]
local function rewardValue(cash: number, experience: number): string
	local parts: { string } = {}
	if cash > 0 then
		table.insert(parts, `+{cash} CASH`)
	end
	if experience > 0 then
		table.insert(parts, `+{experience} XP`)
	end
	-- RewardService never sends a line where both are zero; this is the guard
	-- for the day one is added, not a case reachable today.
	return table.concat(parts, "   ")
end

local function renderRewards(current: View)
	destroyList(rewardClones)

	local receipt = summary

	local panel = current.rewards
	if panel ~= nil then
		--[[
			A player who watched the round from the menu is never sent a
			summary, and neither is one whose packet was dropped. An empty
			rewards box reads as "you earned nothing"; no box reads as "this
			part is not about you", which is the truth in both cases.
		]]
		panel.Visible = receipt ~= nil
	end

	if receipt == nil then
		return
	end

	local list = current.rewardEntries
	local template = current.rewardTemplate
	if list ~= nil and template ~= nil then
		for index, entry in receipt.entries do
			local row = cloneRow(template, list, `Entry{index}`, index, rewardClones)
			setText(row, "LabelLabel", entry.label)
			setText(row, "ValueLabel", rewardValue(entry.cash, entry.experience))
		end
	end

	local cashLabel = current.totalCashLabel
	if cashLabel ~= nil then
		cashLabel.Text = `+{receipt.totalCash} CASH`
	end

	local experienceLabel = current.totalExperienceLabel
	if experienceLabel ~= nil then
		experienceLabel.Text = `+{receipt.totalExperience} XP`
	end
end

local function openResults()
	local current = view
	if current == nil then
		--[[
			Start() has not found the screen yet. Not a miss: it re-applies the
			current state the moment it has, so a player who joined during
			RoundResults still gets the screen, just a beat later.
		]]
		return
	end

	cancelScheduledClear()
	destroyList(podiumClones)
	destroyList(rewardClones)

	local standings = collectStandings()
	applyHeadline(current, standings)
	buildPodium(current, standings)
	renderRewards(current)

	opened = true
	--[[
		Results is NOT exclusive -- it stacks over the HUD and over the menu the
		player is about to be handed back. Nothing else will close it for us,
		which is why the state listener below has to.
	]]
	UIController.open(SCREEN_NAME)
end

local function closeResults()
	if view == nil then
		-- Nothing authored. Asking UIController to close a screen it never
		-- registered is one warning per state change, five a round, forever.
		return
	end

	local wasOpen = opened
	opened = false

	--[[
		Closed whether or not WE opened it. Results does not stack under
		anything -- it is the non-exclusive screen, so no other open() will
		take it down -- and a copy left Enabled in Studio is registered as open
		the moment PlayerGui populates. Unconditional here means that screen
		comes down on the first state change instead of sitting over the menu
		for the rest of the session. Closing an already-closed screen is a
		no-op inside UIController.
	]]
	UIController.close(SCREEN_NAME)

	if not wasOpen then
		--[[
			The receipt survives a close we did not open for, and that guard is
			load-bearing: the summary packet and the state write travel
			different pipes, so a client can be holding the receipt for a round
			whose state write is still in flight. Clearing it on the catch-up
			apply that follows a bind would throw it away seconds before it was
			due on screen. applyState draws the other boundary: once the match
			has moved past RoundActive the receipt is dropped regardless, so
			this guard holds it for a race and never for a round.
		]]
		return
	end

	-- Dropped now rather than at the next open, so last round's receipt can
	-- never be drawn onto this round's screen.
	summary = nil
	scheduleClear()
end

local function applyState(state: Match.MatchState)
	if state == "RoundResults" then
		openResults()
		return
	end

	--[[
		The receipt belongs to ONE RoundResults, and this is where it stops
		being able to reach a later one. Nothing on the packet identifies the
		round it was paid for, so the boundary has to be the match's own clock.

		It survives RoundActive deliberately. The summary packet and the state
		write travel different pipes, so a receipt can land while this client
		still reads RoundActive -- including on the catch-up apply after a bind,
		which is the case closeResults' `wasOpen` guard exists for. Every state
		past that one is past the round the receipt describes, and a receipt
		held that long can only be drawn onto the NEXT round's screen: closing
		without having opened (a player who was still binding when the results
		came up) is exactly the path that used to carry it there.
	]]
	if state ~= "RoundActive" then
		summary = nil
	end

	closeResults()
end

--[[
	Everything under the screen, in one non-yielding pass.

	FindFirstChild, never WaitForChild: the engine copies StarterGui into
	PlayerGui as a whole subtree, so by the time the ScreenGui is there its
	children are too (HUDController.resolve makes the same call for the same
	reason). A typo in an authored name is then one warning at bind rather than
	a ten-second park on every respawn.
]]
local function bind(screen: ScreenGui): View?
	local root = screen:FindFirstChild("Root")
	local panel = if root ~= nil then root:FindFirstChild("Panel") else nil
	if panel == nil then
		log.warn(`{screen:GetFullName()} has no Root/Panel -- Results will not be driven`)
		return nil
	end

	local placeTemplate = findGuiObject(panel, "PlaceTemplate")
	if placeTemplate ~= nil then
		--[[
			A template is a prototype, not content. Both of them sit under Panel
			beside the lists they are cloned into, so one left visible in Studio
			draws a spare row of placeholder text next to the real ones. Hidden
			once here; each clone is made visible individually.
		]]
		placeTemplate.Visible = false
		checkTemplateLabels(placeTemplate, { "PlaceLabel", "NameLabel", "StatsLabel" })
	end

	local rewardTemplate = findGuiObject(panel, "RewardTemplate")
	if rewardTemplate ~= nil then
		rewardTemplate.Visible = false
		checkTemplateLabels(rewardTemplate, { "LabelLabel", "ValueLabel" })
	end

	local rewards = findGuiObject(panel, "Rewards")
	local rewardEntries: GuiObject? = nil
	local totalCashLabel: TextLabel? = nil
	local totalExperienceLabel: TextLabel? = nil
	if rewards ~= nil then
		rewardEntries = findGuiObject(rewards, "Entries")

		local totals = findGuiObject(rewards, "Totals")
		if totals ~= nil then
			totalCashLabel = findLabel(totals, "TotalCashLabel")
			totalExperienceLabel = findLabel(totals, "TotalExperienceLabel")
		end
	end

	-- HeaderLabel and Totals.Rule are never written: they are Studio's copy and
	-- Studio's divider, and a second place to change the wording from is a
	-- second place for it to be wrong.
	return {
		outcomeLabel = findLabel(panel, "OutcomeLabel"),
		scoreLabel = findLabel(panel, "ScoreLabel"),
		standings = findGuiObject(panel, "Standings"),
		placeTemplate = placeTemplate,
		rewards = rewards,
		rewardEntries = rewardEntries,
		rewardTemplate = rewardTemplate,
		totalCashLabel = totalCashLabel,
		totalExperienceLabel = totalExperienceLabel,
	}
end

--[[
	Finds Results, drives it, and RE-finds it for the rest of the session.

	The loop is the whole point, not defensive padding.
	StarterGui.ResetPlayerGuiOnSpawn is on by default and wipes PlayerGui on
	every respawn -- and in this game a player respawns every few seconds -- so
	a controller that bound once and gave up when its screen was destroyed
	would stop showing the end-of-round screen from the player's first death
	onwards, silently and with no error to find. HUDController runs the same
	loop, and UIController re-registers the replacement screen, for exactly
	this reason.

	Destroying:Wait() rather than a connection: there is no handle to forget to
	disconnect, and this thread has nothing else to do in the meantime.
]]
local function attachLoop()
	local playerGui = player:WaitForChild("PlayerGui")
	local everBound = false

	while true do
		local screen = findScreen(playerGui, os.clock() + BIND_TIMEOUT)

		if screen == nil then
			if not everBound then
				log.info("no Results screen authored yet -- nothing to drive")
				return
			end
			--[[
				It was there a moment ago, so this is a re-clone caught
				mid-flight rather than a missing screen. findScreen has already
				spent its budget waiting, so going round again costs a delayed
				rebind and never a hot loop.
			]]
			continue
		end

		local bound = bind(screen)
		if bound == nil then
			-- bind() named what is missing. The copy re-cloned on the next
			-- respawn is the same authored tree, so retrying would only repeat
			-- the same warning forever.
			return
		end

		everBound = true
		-- After the first bind, not before it: bind() above is where the
		-- authored tree is actually inspected, so silencing any earlier would
		-- swallow the one report that is worth having.
		reportedMissing = true
		view = bound

		--[[
			The catch-up. The state listener in Init() fires before this bind
			finishes whenever a player joins mid-results -- and after a respawn
			there is no fresh state change at all -- and openResults() defers
			when it has no view. This is where that deferral is redeemed.
		]]
		applyState(MatchController.getState())

		screen.Destroying:Wait()

		--[[
			Cleared BEFORE anything else touches them. The clones are already
			destroyed with the screen that held them, but the two lists still
			hold references and the pending clear still holds a thread, so
			dropping both is what keeps a re-clone from leaving a growing pile
			of dead instances behind it. `opened` goes with them: the
			replacement screen registers closed, so believing we still had one
			open would cost the next round its results.
		]]
		view = nil
		opened = false
		cancelScheduledClear()
		destroyList(podiumClones)
		destroyList(rewardClones)
	end
end

function ResultsController.Init()
	--[[
		Init, not Start. A packet fired at a client whose listener does not
		exist yet is dropped, not queued, and this one is sent exactly once per
		match -- miss it and the player's receipt is gone for good, with nothing
		in the log to say why (DevConsoleController makes the same argument for
		devAccess).
	]]
	Net.rewardSummary.listen(function(data)
		summary = data

		local current = view
		if opened and current ~= nil then
			-- The screen is already up: the receipt lost the race against the
			-- state write. Repainting is all that is needed -- openResults()
			-- covers the other order by drawing whatever is stored.
			renderRewards(current)
		end
	end)

	--[[
		Registered here so the first fire cannot be missed either. Subscribing
		from Init() is guaranteed to see the replica's first state, because
		Main.client.luau calls Replica.RequestData() only after every Init() has
		run (MatchController.onStateChanged).
	]]
	MatchController.onStateChanged(applyState)
end

function ResultsController.Start()
	-- Parks for the session. The Loader spawns every Start(), so nothing is
	-- waiting on this one to return.
	attachLoop()
end

return ResultsController
