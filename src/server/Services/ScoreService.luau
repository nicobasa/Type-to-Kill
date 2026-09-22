--!strict
--[[
	Kills, deaths, team scores, and the ranking the results screen is built on.

	The authoritative copy lives here, in plain server tables, and is MIRRORED
	into the round replica afterwards. It is never read back out of it: the
	replica is a public client-facing table whose shape belongs to RoundService,
	and a win condition evaluated against a number another service is free to
	rewrite is a win condition that can be lost to an unrelated edit. Writes go
	one way -- here first, replica second.

	LastKillAt is the reason kills are counted in a service of their own rather
	than incremented inline wherever a kill lands. The Free For All tiebreak is
	"who got there first", and that question has no answer after the fact: the
	timestamp has to be stamped in the same slice as the kill it describes.
	Nothing downstream can reconstruct it from a scoreboard.

	resetRound() is public, but the round loop never calls it -- ScoreService
	subscribes to RoundService.onStateChanged itself and clears on the way INTO
	WaitingToPlay rather than on the way out of RoundActive. RewardService reads
	the standings during RoundResults, and a reset at the end of the round would
	hand it an empty scoreboard and pay everyone the participation rate.

	No validation lives here. KillService owns the ladder that decides whether a
	kill happened at all (state, alive, friendly, protected); this is the
	bookkeeping half, and re-running half of that ladder here would only create
	a second place for a legitimate kill to go missing.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local Match = require(ReplicatedStorage.Shared.Match)
local ParticipantService = require(script.Parent.ParticipantService)
local RoundService = require(script.Parent.RoundService)
local TeamService = require(script.Parent.TeamService)

local log = Log.new("ScoreService")

type Score = {
	Kills: number,
	Deaths: number,
	-- workspace:GetServerTimeNow() of the kill that took this player to their
	-- current Kills count. 0 for a player who has not killed yet, which sorts
	-- first and is harmless: it is only ever compared against another player on
	-- the same kill count, and two players on zero kills both hold zero.
	LastKillAt: number,
}

--[[
	One row of the ranking, lowercase-keyed unlike Score and Match.RoundPlayer.
	Those two are stored shapes -- one server-side, one replicated; this is a
	plain return value that exists for the length of a call.
]]
export type Standing = {
	player: Player,
	kills: number,
	deaths: number,
	lastKillAt: number,
}

local playerScores: { [Player]: Score } = {}

-- Every team's key is always present, so getTeamScore never has to answer for
-- a missing one. Teams the round does not play with, and Free For All, simply
-- never increment theirs.
local teamScores: { [Match.TeamId]: number } = { Red = 0, Blue = 0, Green = 0, Yellow = 0 }

local ScoreService = {}

--[[
	The row in the round replica is created by ParticipantService on join and
	destroyed when the player leaves, so a mirror write can arrive after the row
	is already gone -- a kill that lands in the same frame its killer or victim
	disconnects.

	RoundService.writePlayer drops that case itself today (RoundService.luau,
	"A missing row is normal, not an error"), and this check is deliberately
	kept anyway: SERVER-CONTRACT.md promises only "SetValues into Players[key]",
	and SetValues down a path that is not there throws from inside Replica. The
	one path that must not fail is this one -- the victim is already dead by the
	time it runs -- so it does not rest on an unwritten guarantee. The
	server-side count is unaffected either way.
]]
local function writeRow(player: Player, values: { [string]: any })
	if RoundService.getPlayerEntry(player) == nil then
		return
	end
	RoundService.writePlayer(player, values)
end

--[[
	Only the team that just scored is published. writeScores replaces the keys it
	is handed, so restating the other team every kill doubles the packet to carry
	a number that did not change.
]]
local function publishTeamScore(team: Match.TeamId)
	local values: { [string]: number } = {}
	values[team] = teamScores[team]
	RoundService.writeScores(values)
end

-- Config.TeamModes is keyed by the mode id, so a new mode needs a goal there
-- and nothing here.
local function killGoal(mode: Match.TeamMode): number
	return Config.TeamModes[mode.Id].KillGoal
end

local function scoreFor(player: Player): Score
	local score = playerScores[player]
	if score == nil then
		score = { Kills = 0, Deaths = 0, LastKillAt = 0 }
		playerScores[player] = score
	end
	return score
end

--[[
	Kills desc, deaths asc, LastKillAt asc (earlier wins), then UserId asc.

	Every tie is broken explicitly, including the last one, because table.sort is
	not stable and playerScores is a dictionary whose iteration order Luau does
	not fix. Without the UserId clause two players on identical numbers could
	swap places between two calls in the same round -- the results screen and the
	rewards would then disagree about who came second. UserId is unique per
	player and never changes, so this is a total order and table.sort cannot
	reject the comparator.
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
	return a.player.UserId < b.player.UserId
end

--[[
	0 for a player who has not scored this round, never nil. These feed HUD and
	reward arithmetic, and a nil there is an error at the caller rather than a
	zero -- an absent row and a row of zeros mean the same thing to a scoreboard.
]]
function ScoreService.getKills(player: Player): number
	local score = playerScores[player]
	return if score ~= nil then score.Kills else 0
end

function ScoreService.getDeaths(player: Player): number
	local score = playerScores[player]
	return if score ~= nil then score.Deaths else 0
end

function ScoreService.getTeamScore(team: Match.TeamId): number
	return teamScores[team]
end

--[[
	The highest kill count currently on the board -- what a Free For All HUD
	renders as "12 / 30". Players who have left are already gone from
	playerScores, so a leaver cannot hold the lead forever.
]]
function ScoreService.getLeaderKills(): number
	local best = 0
	for _, score in playerScores do
		if score.Kills > best then
			best = score.Kills
		end
	end
	return best
end

--[[
	Both sides of one kill, the team score, the replica mirror and the win check.
	Called by KillService once the kill is already decided.
]]
function ScoreService.recordKill(killer: Player, victim: Player)
	--[[
		Stamped before anything else can yield. Everything below is synchronous
		today, but the value this records is "when the kill happened", and a
		timestamp taken after a mirror write would quietly become "when the
		bookkeeping finished" the first time one of those calls yields.
	]]
	local now = workspace:GetServerTimeNow()

	if killer == victim then
		-- KillService rejects this as `Self` long before it gets here. If one
		-- ever arrives it must not be counted: a self-kill would hand the
		-- player a kill, a death and a fresh tiebreak stamp in one call.
		log.warn(`recordKill() with {killer.Name} as both killer and victim -- dropped`)
		return
	end

	local killerScore = scoreFor(killer)
	killerScore.Kills += 1
	killerScore.LastKillAt = now

	local victimScore = scoreFor(victim)
	victimScore.Deaths += 1

	writeRow(killer, { Kills = killerScore.Kills, LastKillAt = killerScore.LastKillAt })
	writeRow(victim, { Deaths = victimScore.Deaths })

	local mode = RoundService.getTeamMode()
	local goal = killGoal(mode)
	local reachedGoal = false

	if mode.UsesTeams then
		-- Annotated, not inferred. Luau widens the singleton union it infers for
		-- a local, so an unannotated `team` here is plain `string` after the nil
		-- refinement -- which no longer satisfies the TeamId key of teamScores
		-- nor publishTeamScore's parameter. Three strict errors from one omission.
		local team: Match.TeamId? = TeamService.getTeam(killer)
		if team == nil then
			--[[
				A kill by someone with no team in a team mode is a bug upstream,
				not a reason to lose the kill. The personal count above already
				stands; only the team total is skipped, because guessing a team
				here would credit the wrong side and possibly end the round.
			]]
			log.warn(`{killer.Name} scored in {mode.DisplayName} with no team -- kill counted, team score unchanged`)
		else
			teamScores[team] += 1
			publishTeamScore(team)
			reachedGoal = teamScores[team] >= goal
		end
	else
		reachedGoal = killerScore.Kills >= goal
	end

	--[[
		The state re-check is not redundant with KillService's: the kill was
		validated before the victim died, and endRound() outside RoundActive is
		a transition RoundService is obliged to refuse and log. Asking here keeps
		that refusal out of the log for a race nobody can act on.
	]]
	if reachedGoal and RoundService.isRoundActive() then
		RoundService.endRound()
	end
end

--[[
	Ranked, deterministic, and free of players who have left the server.

	Two sources, deliberately. playerScores only has a row for someone who has
	killed or died, so a player who joined the round and did neither would be
	invisible here -- and RewardService pays participation off this list, so
	invisible means unpaid. ParticipantService supplies those: anyone still in
	the round (playing or in a killcam) belongs on the board at zero.
]]
function ScoreService.getStandings(): { Standing }
	local standings: { Standing } = {}
	local listed: { [Player]: boolean } = {}

	for player, score in playerScores do
		--[[
			PlayerRemoving clears these rows, so this only catches the window
			where a player is mid-disconnect. Cheap, and the alternative is a
			results screen crediting someone who is not in the server to
			receive it.
		]]
		if player.Parent ~= Players then
			continue
		end
		listed[player] = true
		table.insert(standings, {
			player = player,
			kills = score.Kills,
			deaths = score.Deaths,
			lastKillAt = score.LastKillAt,
		})
	end

	for _, player in Players:GetPlayers() do
		if listed[player] or not ParticipantService.isInRound(player) then
			continue
		end
		table.insert(standings, { player = player, kills = 0, deaths = 0, lastKillAt = 0 })
	end

	table.sort(standings, byRank)
	return standings
end

--[[
	Back to zero for a new round, server-side and in the replica.

	Every present player's row is rewritten, not just the ones that scored: the
	rows outlive a round (ParticipantService creates them on join), so a player
	who sat out the reset with last round's numbers still on screen is exactly
	what dropping the loop would produce.
]]
function ScoreService.resetRound()
	table.clear(playerScores)

	-- Indexed, and annotated. `teamScores.Red = 0` does not typecheck at all --
	-- a table keyed by the TeamId union has no named properties to reach for --
	-- and an unannotated loop variable comes out of Match.TEAM_ORDER widened to
	-- plain `string`, which the union key then rejects. Match.TEAM_ORDER is also
	-- the one list that already knows which teams exist.
	-- Every team, not just this round's: a Green score left over from a
	-- four-team round would otherwise still be on the wire in the next one.
	-- SetValues merges, so only a key that is written is cleared.
	local zeroed: { [string]: number } = {}
	for _, team: Match.TeamId in Match.TEAM_ORDER do
		teamScores[team] = 0
		zeroed[team] = 0
	end

	RoundService.writeScores(zeroed)
	for _, player in Players:GetPlayers() do
		-- A fresh table per player: SetValues is handed this reference, and one
		-- shared table reused across writes is a shape nobody expects to alias.
		writeRow(player, { Kills = 0, Deaths = 0, LastKillAt = 0 })
	end
end

function ScoreService.Init()
	Players.PlayerRemoving:Connect(function(player)
		--[[
			The player's own row goes; their contribution to the team score
			stays. Subtracting it would rewind a score the team actually earned,
			and could un-win a round that had already met the goal.
		]]
		playerScores[player] = nil
	end)

	RoundService.onStateChanged(function(state: Match.MatchState)
		if state == "WaitingToPlay" then
			ScoreService.resetRound()
		end
	end)
end

function ScoreService.Start()
	log.info("ready")
end

return ScoreService
