--!strict
--[[
	Cash and XP payouts: one per kill, one per match.

	Everything this service sends a client is a RECEIPT for a write that has
	already happened -- the cash/experience fields on Net.codeResult, every
	line of Net.rewardSummary. No client packet can ask for a grant, and a
	client that drops a receipt loses a screen, never a reward.

	WHY awardKill RETURNS AMOUNTS INSTEAD OF A BOOLEAN

	CashService.add and LevelService.addExperience both refuse when a player's
	profile is not loaded -- a joiner whose data is still coming down, someone
	already halfway out the door -- and report it with `false`. A caller that
	took success for granted would flash "+10 CASH" over a balance that never
	moved, with the real balance on screen an inch away. So a refusal comes
	back as 0: the pair returned here is what was ACTUALLY written, never the
	nominal figure out of Config.

	WHY THERE IS A LEDGER RATHER THAN kills * KillCash

	The match summary itemises the kill money as well as the match bonus.
	Recomputing that line at results time from the scoreboard agrees with
	reality only while every grant of the round succeeded; the first refusal
	makes the recomputed figure over-report, silently and for good. So each
	grant is accumulated in `earnings` as it happens, and the summary is
	assembled from those totals.

	Per-player state: `earnings` only. Cleared on PlayerRemoving, and again at
	the start of every round.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CashService = require(script.Parent.CashService)
local Config = require(ReplicatedStorage.Shared.Config)
local LevelService = require(script.Parent.LevelService)
local Log = require(ReplicatedStorage.Shared.Log)
local Match = require(ReplicatedStorage.Shared.Match)
local Net = require(ReplicatedStorage.Shared.Net)
local ParticipantService = require(script.Parent.ParticipantService)
local RoundService = require(script.Parent.RoundService)
local ScoreService = require(script.Parent.ScoreService)
local TeamService = require(script.Parent.TeamService)

local log = Log.new("RewardService")

type Award = { resultText: string, cash: number, experience: number }

type Earnings = { kills: number, cash: number, experience: number }

type SummaryEntry = { label: string, cash: number, experience: number }

--[[
	Net.rewardSummary carries every figure as a uint32, so a total past this
	wraps on the wire -- 4294967296 arrives as 0. Unreachable at today's
	Config values; it costs one comparison, and the alternative is a receipt
	naming a number the player never got.
]]
local MAX_WIRE_AMOUNT = 4294967295

--[[
	The match tiers, resolved from Config once and keyed by outcome rather
	than picked apart by an `if` ladder at the call site. `resultText` is the
	headline the results screen draws and doubles as the label of the bonus
	line -- one string, so the two can never disagree.
]]
local TEAM_AWARDS: { Win: Award, Draw: Award, Loss: Award } = {
	Win = {
		resultText = "VICTORY",
		cash = Config.Rewards.Teams.WinCash,
		experience = Config.Rewards.Teams.WinExperience,
	},
	Draw = {
		resultText = "DRAW",
		cash = Config.Rewards.Teams.DrawCash,
		experience = Config.Rewards.Teams.DrawExperience,
	},
	Loss = {
		resultText = "DEFEAT",
		cash = Config.Rewards.Teams.LossCash,
		experience = Config.Rewards.Teams.LossExperience,
	},
}

-- Index = finishing place. Anything past the end takes the participation tier.
local PLACEMENT_AWARDS: { Award } = {
	{
		resultText = "1ST PLACE",
		cash = Config.Rewards.FreeForAll.FirstCash,
		experience = Config.Rewards.FreeForAll.FirstExperience,
	},
	{
		resultText = "2ND PLACE",
		cash = Config.Rewards.FreeForAll.SecondCash,
		experience = Config.Rewards.FreeForAll.SecondExperience,
	},
	{
		resultText = "3RD PLACE",
		cash = Config.Rewards.FreeForAll.ThirdCash,
		experience = Config.Rewards.FreeForAll.ThirdExperience,
	},
}

local ORDINAL_SUFFIXES = { "ST", "ND", "RD" }

local earnings: { [Player]: Earnings } = {}

--[[
	One flag per visit to RoundResults. RoundService fires its listeners on
	every state write and Match.canTransition treats a state moving to itself
	as legal, so a re-asserted RoundResults is not a bug -- but paying
	everyone a second time for it would be.
]]
local awarded = false

local RewardService = {}

local function clampToWire(amount: number): number
	return math.min(amount, MAX_WIRE_AMOUNT)
end

--[[
	"11TH", not "11ST". The teens are the exception every suffix table gets
	wrong: they end in 1, 2 and 3 but all take TH. Only reached from 4th place
	down -- the podium carries its own text -- so an eleven-player Free For
	All is exactly where this earns its keep.
]]
local function ordinal(place: number): string
	local teens = place % 100
	if teens >= 11 and teens <= 13 then
		return `{place}TH`
	end
	return `{place}{ORDINAL_SUFFIXES[place % 10] or "TH"}`
end

local function ledgerFor(player: Player): Earnings
	local existing = earnings[player]
	if existing ~= nil then
		return existing
	end

	local created: Earnings = { kills = 0, cash = 0, experience = 0 }
	earnings[player] = created
	return created
end

--[[
	Grant one match tier and send that player their receipt.

	Each grant is asked for only when there is something to grant:
	Validate.amount rejects 0, so a tier deliberately tuned down to nothing
	would otherwise fill the log with warnings about a choice someone made on
	purpose.
]]
local function payout(player: Player, award: Award)
	local cash = 0
	if award.cash > 0 and CashService.add(player, award.cash) then
		cash = award.cash
	end

	local experience = 0
	if award.experience > 0 and LevelService.addExperience(player, award.experience) then
		experience = award.experience
	end

	local entries: { SummaryEntry } = {}
	local earned = earnings[player]

	if earned ~= nil and (earned.cash > 0 or earned.experience > 0) then
		table.insert(entries, {
			label = `KILLS ({earned.kills})`,
			cash = clampToWire(earned.cash),
			experience = clampToWire(earned.experience),
		})
	end

	if cash > 0 or experience > 0 then
		table.insert(entries, { label = award.resultText, cash = cash, experience = experience })
	end

	local totalCash = cash
	local totalExperience = experience
	if earned ~= nil then
		totalCash += earned.cash
		totalExperience += earned.experience
	end

	--[[
		Sent even when every grant was refused and both totals are zero: the
		headline IS the results screen, and a player owed nothing still has to
		be told the match ended and how it went.
	]]
	Net.rewardSummary.sendTo({
		resultText = award.resultText,
		entries = entries,
		totalCash = clampToWire(totalCash),
		totalExperience = clampToWire(totalExperience),
	}, player)
end

--[[
	The ranked list of everyone owed something.

	Order and membership both come from ScoreService.getStandings, which
	already drops players who have left the server and already lists a
	participant who neither killed nor died (ScoreService.luau:249) -- so a
	zero-and-zero player is paid here rather than forgotten.

	The isInRound filter is still this service's own: a standings row outlives
	the round phase it was earned in, so someone who scored and then went back
	to the menu is on that board but is not owed a match reward.
]]
local function collectParticipants(): { Player }
	local participants: { Player } = {}

	for _, standing in ScoreService.getStandings() do
		if ParticipantService.isInRound(standing.player) then
			table.insert(participants, standing.player)
		end
	end

	return participants
end

--[[
	How a team finished: Win for sole first place, Draw for a tie for first,
	Loss for anything else. Measured against every team the mode plays with,
	not against "the other team" -- with four sides there is no one other team,
	and comparing against a single one would let three teams all "win".
]]
local function teamOutcome(team: Match.TeamId, teams: { Match.TeamId }): Award
	local own = ScoreService.getTeamScore(team)
	local best = own
	local tiedAtBest = 0
	for _, other: Match.TeamId in teams do
		local score = ScoreService.getTeamScore(other)
		if score > best then
			best = score
		end
	end
	if own < best then
		return TEAM_AWARDS.Loss
	end
	for _, other: Match.TeamId in teams do
		if ScoreService.getTeamScore(other) == best then
			tiedAtBest += 1
		end
	end
	return if tiedAtBest > 1 then TEAM_AWARDS.Draw else TEAM_AWARDS.Win
end

local function awardTeamMatch(participants: { Player }, teams: { Match.TeamId })
	for _, player in participants do
		-- Annotated, not inferred: refining an inferred TeamId against nil
		-- widens it to plain `string`, which teamOutcome below refuses.
		local team: Match.TeamId? = TeamService.getTeam(player)
		if team == nil then
			--[[
				In the round but on no side. Only reachable if the team was
				cleared between the last spawn and now; there is no Team
				Deathmatch participation tier in Config, and inventing one
				here would be a number nobody balanced.

				Logged rather than skipped quietly: this is the one path where
				a participant is paid nothing at all and gets no results
				screen, and "why did I see nothing?" has to be answerable from
				the server log.
			]]
			log.warn(`{player.Name} finished the round with no team -- no match reward`)
			continue
		end

		payout(player, teamOutcome(team, teams))
	end
end

local function awardFreeForAll(participants: { Player })
	for place, player in participants do
		local placed = PLACEMENT_AWARDS[place]
		if placed ~= nil then
			payout(player, placed)
			continue
		end

		payout(player, {
			resultText = `{ordinal(place)} PLACE`,
			cash = Config.Rewards.FreeForAll.ParticipationCash,
			experience = Config.Rewards.FreeForAll.ParticipationExperience,
		})
	end
end

local function awardMatch()
	local participants = collectParticipants()
	if #participants == 0 then
		return
	end

	local mode = RoundService.getTeamMode()
	if mode.UsesTeams then
		awardTeamMatch(participants, mode.Teams)
	else
		awardFreeForAll(participants)
	end

	log.debug(`match rewards paid to {#participants} player(s) in {mode.Id}`)
end

local function onStateChanged(state: Match.MatchState, _previous: Match.MatchState)
	if state ~= "RoundResults" then
		awarded = false

		if state == "WaitingToPlay" then
			-- The boundary ScoreService resets its round stats at. Sharing it
			-- is what keeps the receipt and the scoreboard describing the same
			-- round.
			table.clear(earnings)
		end
		return
	end

	if awarded then
		return
	end
	awarded = true

	awardMatch()
end

--[[
	Pay for one kill. Returns (cash, experience) ACTUALLY granted -- 0 for
	either one that was refused -- so KillService can put a figure on the
	killer's toast that their balance will agree with.

	The kill is counted in the ledger whether or not the money landed: the
	count describes the round, the two totals describe what was written.
]]
function RewardService.awardKill(player: Player): (number, number)
	--[[
		The `> 0` guards are the same ones payout() carries, and they matter
		more here: Validate.amount rejects 0, so a KillCash of 0 -- a real way
		to tune a mode -- would log a rejection warning on EVERY kill in the
		server rather than once per match.
	]]
	local killCash = Config.Rewards.KillCash
	local cash = 0
	if killCash > 0 and CashService.add(player, killCash) then
		cash = killCash
	end

	local killExperience = Config.Rewards.KillExperience
	local experience = 0
	if killExperience > 0 and LevelService.addExperience(player, killExperience) then
		experience = killExperience
	end

	local earned = ledgerFor(player)
	earned.kills += 1
	earned.cash += cash
	earned.experience += experience

	return cash, experience
end

function RewardService.Init()
	RoundService.onStateChanged(onStateChanged)

	Players.PlayerRemoving:Connect(function(player: Player)
		--[[
			A {[Player]: T} nobody clears holds a reference to everyone who has
			ever been in the server. Dropping the ledger also forfeits the
			summary for a player who leaves mid-round, which is the same answer
			ScoreService gives by removing them from the standings.
		]]
		earnings[player] = nil
	end)
end

function RewardService.Start()
	log.info("ready")
end

return RewardService
