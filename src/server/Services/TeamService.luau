--!strict
--[[
	Who is on which team, and whether one more player may join one.

	THE COUNT IS A TABLE IN THIS FILE, NOT Team:GetPlayers()

	`Teams.Red:GetPlayers()` is a derived view of a property that anything in
	the place can write -- another script assigning `player.Team`, a Team
	instance left in the place file, a plugin poking at it during a Studio
	test. A balance rule decided from that is a rule whose input has no owner.
	`assignments` below is written by this file and nothing else, and is
	cleared on PlayerRemoving whether or not anyone remembered to call
	clear(), so it is the only answer to "how many are on Red" that can be
	defended. `player.Team` is still set -- the engine needs it, and so does
	anything reading Team off a character -- but it is the OUTPUT of the
	decision here, never the input to it.

	THE SAME-FRAME DOUBLE JOIN

	Two players pressing RED in the same frame is the case the re-check inside
	assign() exists for. canJoin() on its own is advisory: by the time a caller
	acts on the answer, someone else may have taken the last slot. assign()
	asks again against the live table, and the check, the roster write and the
	property write happen in one slice with no yield anywhere in it -- so the
	second request reads a count that already includes the first. This is the
	read-compute-write argument CashService.luau:3 makes about balances, with a
	team slot as the contested resource instead of cash.

	Nothing here reads the round's mode. The caller hands assign() the sides
	the round plays with (Match.TeamMode.Teams), so a two-team round cannot put
	anyone on Green however they ask. Free For All simply never calls assign(),
	and every player's Team stays nil.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Teams = game:GetService("Teams")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local Match = require(ReplicatedStorage.Shared.Match)

local log = Log.new("TeamService")

--[[
	The authoritative roster. Absence means "on no team", which covers both a
	Free For All player and a Team Deathmatch player who has not picked yet --
	neither counts towards the balance.

	The value type carries the `?` because absence is a state this file writes
	on purpose, not an accident: clear() and the leave handler remove rows, and
	assign() drops a row before re-testing the balance. Without it Luau accepts
	only a literal `nil` write and rejects restoring a maybe-nil `previous`.
]]
local assignments: { [Player]: Match.TeamId? } = {}

-- Filled in Init(). Empty until then, which is why every write path treats a
-- missing Team instance as a refusal instead of indexing nil.
local teamInstances: { [Match.TeamId]: Team } = {}

--[[
	Counted on demand rather than kept in a running total. A cached pair of
	counters is a second source of truth, and the failure mode of a missed
	decrement is a team that is permanently one slot short with nothing in the
	logs to say so. Fewer than fifty players makes the loop free.
]]
local function countTeams(): { [Match.TeamId]: number }
	local counts: { [Match.TeamId]: number } = { Red = 0, Blue = 0, Green = 0, Yellow = 0 }
	-- Annotated: an inferred loop value widens TeamId to `string`, which is
	-- not a key of the TeamId-keyed counts.
	for _, team: Match.TeamId? in assignments do
		if team ~= nil then
			counts[team] += 1
		end
	end
	return counts
end

--[[
	The Team instance for a definition, reusing one the place already has
	under that name.

	Reuse rather than an unconditional Instance.new: a place file that already
	contains a Team called Red would end up with two of them, and every
	`Teams:FindFirstChild("Red")` in the game -- ours and anyone else's --
	would then be a coin flip between the one players are on and the one they
	are not.
]]
local function ensureTeam(definition: Match.TeamDefinition): Team
	local team: Team
	local existing = Teams:FindFirstChild(definition.Id)
	if existing ~= nil and existing:IsA("Team") then
		team = existing
	else
		team = Instance.new("Team")
	end

	-- Named for the Id, NOT DisplayName. The name is what code and instance
	-- paths address; "RED" is a string for the screen, and the UI reads it
	-- from Match.TEAMS where it belongs.
	team.Name = definition.Id
	team.TeamColor = definition.TeamBrickColor

	--[[
		Roblox would otherwise drop every player onto a team the instant they
		connect -- before ParticipantService has even shown them the menu, and
		without passing through assign(), so the engine and the roster would
		disagree from the very first join. Team membership here is only ever
		the result of an assign().
	]]
	team.AutoAssignable = false

	team.Parent = Teams
	return team
end

local TeamService = {}

function TeamService.getTeam(player: Player): Match.TeamId?
	return assignments[player]
end

--[[
	Would one more player on `team` keep the largest and smallest of `teams`
	(the sides the round plays with) within Config.Teams.MaxImbalance?

	Advisory: nothing may act on this without assign() asking again, for the
	reason the header gives. It answers for a player who is currently on NO
	team -- assign() handles a switch by taking the player off their old side
	first, because counting someone on both sides at once refuses exactly the
	swaps that would have evened the teams out.

	TeamSelectController.wouldExceedImbalance mirrors this rule so the client
	can grey out a button before it is refused. Change them together.
]]
function TeamService.canJoin(team: Match.TeamId, teams: { Match.TeamId }): boolean
	-- A team the round does not play with is never joinable, whatever the
	-- counts say. The static type is only a promise the caller made.
	if table.find(teams, team) == nil then
		return false
	end

	local counts = countTeams()
	counts[team] += 1

	local largest, smallest = -math.huge, math.huge
	for _, side: Match.TeamId in teams do
		local count = counts[side]
		largest = math.max(largest, count)
		smallest = math.min(smallest, count)
	end
	return largest - smallest <= Config.Teams.MaxImbalance
end

--[[
	Put `player` on `team`. Returns false, having changed nothing, if the team
	is full, the id is not one of `teams` (the sides the round plays with), or
	the player has already left.
]]
function TeamService.assign(player: Player, team: Match.TeamId, teams: { Match.TeamId }): boolean
	-- Annotated optional because it genuinely is: teamInstances is empty until
	-- Init() fills it, and Luau types a table index as the value type rather
	-- than value-or-nil. The check below is the point of the line.
	local instance: Team? = teamInstances[team]
	if instance == nil then
		-- Either an id that names no team -- ParticipantService validates the
		-- packet, but this is the file that has to be right regardless of who
		-- calls it -- or Init() has not run.
		log.warn(`assign() on {player.Name} for unknown team "{team}" -- refused`)
		return false
	end

	if player.Parent ~= Players then
		-- PlayerRemoving has already cleared this player. Writing the roster
		-- now puts back a row nothing will ever remove, and that slot stays
		-- occupied for the rest of the server's life.
		return false
	end

	-- Annotated, not inferred: comparing an unannotated TeamId against another
	-- widens it back to plain `string` under refinement, and the restore below
	-- would then not typecheck against the roster's value type.
	local previous: Match.TeamId? = assignments[player]
	if previous == team then
		-- Re-asserting the team you already hold is not a join, and must not
		-- be refused by a balance check that counts you on it twice. The
		-- property is still written rather than skipped, so a true return
		-- always means player.Team agrees with the roster no matter what else
		-- in the place touched it in between.
		player.Team = instance
		return true
	end

	--[[
		A switch frees the old slot before it takes the new one, so drop the
		player first and let canJoin see the counts the move would actually
		produce. Restoring `previous` on refusal is safe precisely because
		nothing between the drop and the write yields.
	]]
	assignments[player] = nil
	if not TeamService.canJoin(team, teams) then
		assignments[player] = previous
		return false
	end

	assignments[player] = team
	player.Team = instance
	return true
end

--[[
	Take `player` off their team. Safe on a player who is on none -- the leave
	path calls it unconditionally rather than asking first.
]]
function TeamService.clear(player: Player)
	assignments[player] = nil
	-- Clearing the property too, because a stale player.Team leaves someone
	-- coloured and sorted onto a team the roster says they left.
	--
	-- The cast is against the definitions, not the engine: globalTypes.d.luau
	-- declares `Player.Team: Team` with no `?` (line 16032), when nil is both
	-- legal and the documented way to take a player off every team -- it is
	-- also the state every player is in before their first assign(), and the
	-- whole of Free For All. Narrow and local to this one write.
	player.Team = nil :: any
end

function TeamService.Init()
	--[[
		No Priority. Nothing can read a team during the Init phase -- the
		Loader forbids calling another service from Init() -- so the Team
		instances only have to exist before the first Start(), which they do.
	]]
	-- Annotated: the loop variable off `{ TeamId }` infers as plain `string`,
	-- which is not a key of the TeamId-keyed teamInstances table.
	for _, teamId: Match.TeamId in Match.TEAM_ORDER do
		teamInstances[teamId] = ensureTeam(Match.TEAMS[teamId])
	end

	--[[
		The roster is this service's own per-player table, so it does its own
		cleanup. Leaning on ParticipantService.leaveMatch to call clear() would
		mean a slot stays occupied for the rest of the server every time a
		player disconnects down a path that service did not anticipate.
	]]
	Players.PlayerRemoving:Connect(function(player: Player)
		assignments[player] = nil
	end)
end

function TeamService.Start()
	log.info("ready")
end

return TeamService
