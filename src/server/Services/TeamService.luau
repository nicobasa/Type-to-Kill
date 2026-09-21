--!strict
--[[
	Who is on Red, who is on Blue, and whether one more player may join them.

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

	Nothing here knows about game modes. Free For All simply never calls
	assign(), and every player's Team stays nil.
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
local function countTeams(): (number, number)
	local red, blue = 0, 0
	for _, team in assignments do
		if team == "Red" then
			red += 1
		else
			blue += 1
		end
	end
	return red, blue
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

function TeamService.getCounts(): { Red: number, Blue: number }
	local red, blue = countTeams()
	-- A fresh table every call. Handing out an internal one lets a caller edit
	-- the roster by editing what reads like a report.
	return { Red = red, Blue = blue }
end

--[[
	Would one more player on `team` keep the sides within
	Config.Teams.MaxImbalance?

	Advisory: nothing may act on this without assign() asking again, for the
	reason the header gives. It answers for a player who is currently on NO
	team -- assign() handles a switch by taking the player off their old side
	first, because counting someone on both sides at once refuses exactly the
	swaps that would have evened the teams out.
]]
function TeamService.canJoin(team: Match.TeamId): boolean
	if Match.TEAMS[team] == nil then
		--[[
			The count below is an if/else over the two ids, so an id that is
			neither would fall down the Blue branch -- a string that came off a
			client packet quietly getting an answer about a team it did not
			name. assign() never reaches here with one, but canJoin is public
			and the static type is only a promise the caller made.
		]]
		return false
	end

	local red, blue = countTeams()
	if team == "Red" then
		red += 1
	else
		blue += 1
	end
	return math.abs(red - blue) <= Config.Teams.MaxImbalance
end

--[[
	Put `player` on `team`. Returns false, having changed nothing, if the team
	is full, the id is not a team, or the player has already left.
]]
function TeamService.assign(player: Player, team: Match.TeamId): boolean
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
	if not TeamService.canJoin(team) then
		assignments[player] = previous
		return false
	end

	assignments[player] = team
	player.Team = instance
	return true
end

--[[
	Put `player` on whichever side needs them, and report which.

	The side picked below is the smaller of the counts taken WITHOUT this
	player, which is exactly the pair assign() measures after it drops them --
	so the gap it checks is either one narrower than it was or 1, and with any
	MaxImbalance >= 1 the assign cannot be refused for balance. It can still
	refuse for a player who has already left, and then the id returned is the
	side they WOULD have taken -- there is no honest team to report for someone
	who is gone, and the signature has nowhere to say so.
]]
function TeamService.autoAssign(player: Player): Match.TeamId
	-- Annotated for the same reason as in assign(): the comparisons below
	-- widen an inferred TeamId to `string`, which then will not satisfy the
	-- TeamId return type on the `team = previous` branch.
	local previous: Match.TeamId? = assignments[player]

	--[[
		Everyone except this player. Their own row is not evidence about where
		they belong, and counting it makes the lone Red player look like the
		reason Red is ahead: autoAssign would move them to Blue, and the next
		call would move them back.
	]]
	local red, blue = countTeams()
	if previous == "Red" then
		red -= 1
	elseif previous == "Blue" then
		blue -= 1
	end

	local team: Match.TeamId
	if red < blue then
		team = "Red"
	elseif blue < red then
		team = "Blue"
	elseif previous ~= nil then
		-- The rest of the server is even, so the side they are already on is
		-- as good as the other one. Staying put beats a coin flip that re-teams
		-- someone mid-match for nothing.
		team = previous
	else
		-- Even sides and no team yet. Alternating would be predictable enough
		-- to game by timing a join, so coin-flip it.
		team = if math.random() < 0.5 then "Red" else "Blue"
	end

	TeamService.assign(player, team)
	return team
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
