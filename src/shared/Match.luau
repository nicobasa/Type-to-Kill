--!strict
--[[
	The vocabulary of a match: its states, its modes, its teams, and the only
	legal moves between states.

	A plain module (ARCHITECTURE.md Recipe 3). Shared because the client has to
	render whatever state the server is in, and a client-side copy of "what
	states exist" that drifts from the server's is how a menu ends up stuck on
	a screen the server left ten seconds ago.

	WHY THE STATE MACHINE IS DATA, NOT `if` STATEMENTS

	Booleans scattered across services (`isVoting`, `roundRunning`,
	`resultsShowing`) can represent states that cannot exist -- voting AND
	results at once -- and nothing catches it, because no single place ever
	sees more than one flag. One enum plus an explicit TRANSITIONS table makes
	the illegal states unrepresentable and the legal moves reviewable in ten
	lines. RoundService is the only writer; everything else observes.

	WHY TeamSelect IS NOT A MatchState

	The design brief lists TEAM_SELECTION between WAITING_TO_PLAY and
	ROUND_ACTIVE. As a GLOBAL state it would be wrong: a player who joins the
	server eight minutes into a live Team Deathmatch still has to pick a team,
	and the match is emphatically not going to leave RoundActive to let them.
	Team selection is therefore a PER-PLAYER phase (`PlayerPhase`) that runs
	against whatever global state is current. Same steps for the player, no lie
	in the model.
]]

export type MatchState = "Lobby" | "Voting" | "MapLoading" | "WaitingToPlay" | "RoundActive" | "RoundResults"

--[[
	Where ONE player is, independent of the match. A late joiner walks
	Menu -> TeamSelect -> Playing while the match sits in RoundActive
	throughout.

	Killcam is deliberately distinct from Menu: a dead player is still IN the
	round -- they hold a scoreboard entry, they are owed a respawn, and they
	must not be handed the menu's Play button.
]]
export type PlayerPhase = "Menu" | "TeamSelect" | "Playing" | "Killcam"

export type GameModeId = "TeamDeathmatch" | "FreeForAll"

export type TeamId = "Red" | "Blue"

export type GameMode = {
	Id: GameModeId,
	DisplayName: string,
	-- Drives the whole TDM/FFA fork: team select, friendly-fire rejection,
	-- which score HUD is drawn, how placement is computed. Read this, never
	-- compare Id to a literal at a call site.
	UsesTeams: boolean,
}

export type TeamDefinition = {
	Id: TeamId,
	DisplayName: string,
	-- For the Team instance, which takes a BrickColor and nothing else.
	TeamBrickColor: BrickColor,
	-- For UI. Never the sole carrier of meaning -- every team-coloured element
	-- also spells RED or BLUE, because roughly one player in twelve cannot
	-- separate these two hues reliably.
	Color: Color3,
}

--[[
	DEFAULT_MODE lives in the constructor, not below with the other constants,
	and must stay there.

	Luau widens a value ASSIGNED to a new property of this table:
	`Match.DEFAULT_MODE = "TeamDeathmatch" :: GameModeId` reached every reader
	as `string | string`, and so did assigning from an annotated local. Three
	files had to re-cast it at their call site. A field written in the table
	constructor keeps its cast type, which was measured: moving it here and
	deleting those three casts left the type gate clean.

	This only matters for scalars. The array casts below (`:: { GameModeId }`)
	keep their element types as ordinary assignments. So a new constant whose
	readers need a singleton union goes here, and anything else goes below.
]]
local Match = {
	DEFAULT_MODE = "TeamDeathmatch" :: GameModeId,
}

--[[
	from -> the set of states it may move to.

	Read it as the round loop, with one escape: every state may fall back to
	Lobby, for "the last player left mid-round". A transition missing from here
	is a bug caught at the call site by Match.canTransition rather than a
	silently reordered match.
]]
local TRANSITIONS: { [string]: { MatchState } } = {
	Lobby = { "Voting" },
	Voting = { "MapLoading", "Lobby" },
	MapLoading = { "WaitingToPlay", "Lobby" },
	WaitingToPlay = { "RoundActive", "Lobby" },
	RoundActive = { "RoundResults", "Lobby" },
	RoundResults = { "Lobby" },
}

--[[
	NOTE ON THE `::` CASTS BELOW -- do not "tidy" them into annotations.

	`Match.STATES: { MatchState } = { ... }` is not valid Luau: a type
	annotation is only legal on a local or a function parameter, never on a
	table-property assignment. The cast is the supported spelling
	(.claude/rules/quality-gate.md, Gate 2, trap #1).
]]
Match.STATES = { "Lobby", "Voting", "MapLoading", "WaitingToPlay", "RoundActive", "RoundResults" } :: { MatchState }

Match.MODES = {
	TeamDeathmatch = {
		Id = "TeamDeathmatch",
		DisplayName = "Team Deathmatch",
		UsesTeams = true,
	},
	FreeForAll = {
		Id = "FreeForAll",
		DisplayName = "Free For All",
		UsesTeams = false,
	},
} :: { [string]: GameMode }

-- Vote order and UI order. A dictionary has none, and "the mode buttons moved
-- between rounds" is a real bug from iterating one.
Match.MODE_ORDER = { "TeamDeathmatch", "FreeForAll" } :: { GameModeId }

Match.TEAMS = {
	Red = {
		Id = "Red",
		DisplayName = "RED",
		TeamBrickColor = BrickColor.new("Bright red"),
		Color = Color3.fromRGB(226, 72, 72),
	},
	Blue = {
		Id = "Blue",
		DisplayName = "BLUE",
		TeamBrickColor = BrickColor.new("Bright blue"),
		Color = Color3.fromRGB(64, 132, 226),
	},
} :: { [string]: TeamDefinition }

Match.TEAM_ORDER = { "Red", "Blue" } :: { TeamId }

--[[
	True if `to` is reachable from `from` in one step. Same-state is allowed
	and is a no-op, so a service that re-asserts its own state is not an error.
]]
function Match.canTransition(from: MatchState, to: MatchState): boolean
	if from == to then
		return true
	end
	local allowed = TRANSITIONS[from]
	if allowed == nil then
		return false
	end
	return table.find(allowed, to) ~= nil
end

--[[
	Wire guards. Everything below takes `any`, on purpose: these exist to be
	called on values that arrived from a client packet or a replicated table,
	where the static type is a promise nobody kept.
]]
function Match.isState(value: any): boolean
	return type(value) == "string" and table.find(Match.STATES, value :: MatchState) ~= nil
end

function Match.isModeId(value: any): boolean
	return type(value) == "string" and Match.MODES[value] ~= nil
end

function Match.isTeamId(value: any): boolean
	return type(value) == "string" and Match.TEAMS[value] ~= nil
end

--[[ The other team. Total over TeamId, so no caller writes the `if` itself. ]]
function Match.opposingTeam(team: TeamId): TeamId
	return if team == "Red" then "Blue" else "Red"
end

--[[
	THE ROUND REPLICA -- the shared, public, whole-server state.

	Player data uses a PRIVATE replica per player (DataService). The round is
	the opposite shape: one replica, `:Replicate()`d to everyone, holding what
	every client must agree on -- what state the match is in, how long is left,
	the scores, the vote tallies, and the public scoreboard row for each player.

	It is a Replica and not a stream of ByteNet packets for the reason
	NETWORKING-AND-DATA.md gives: a player who joins eight minutes into a round
	needs the timer, the scores and the mode, and an event they were not present
	for cannot give them that. Replica subscribes future players automatically,
	so a late joiner and a founding player take the identical code path.

	Shape (RoundService is the ONLY writer):

		State         MatchState
		ModeId        GameModeId
		MapId         string, "" while no map is loaded
		PhaseEndsAt   absolute workspace:GetServerTimeNow(), or 0 when the
		              current phase has no deadline. Absolute, NOT a countdown:
		              a remaining-seconds field would need a packet per second
		              and would still drift. Every client subtracts its own
		              GetServerTimeNow(), which Roblox keeps synchronised.
		Scores        { Red: number, Blue: number }
		Vote          { MapChoices: {string}, MapVotes: {[string]: number},
		                ModeVotes: {[string]: number} }
		Players       { [playerKey]: RoundPlayer }

	PUBLIC means public: everything here reaches every client, so nothing that
	must stay secret may be added to it. Four-digit codes are NOT in this table
	-- see CodeService.
]]
Match.REPLICA_TOKEN = "MatchState"

export type RoundPlayer = {
	DisplayName: string,
	Level: number,
	-- "" in Free For All, where there are no teams.
	Team: string,
	Phase: PlayerPhase,
	Kills: number,
	Deaths: number,
	Alive: boolean,
	-- GetServerTimeNow() of the kill that took them to their current Kills
	-- count. The Free For All tiebreak needs "who got there first"
	-- (design brief 44), and that question has no answer after the fact unless
	-- it is recorded as it happens.
	LastKillAt: number,
}

--[[
	The key a player occupies in Round.Players.

	The "U" prefix is not decoration. Replica forbids gaps in numeric tables
	(ARCHITECTURE.md, Data section), and a bare tostring(userId) produces
	"12345" -- a string that any helper doing tonumber() on a path segment
	turns back into a number, which is exactly how a dictionary becomes a
	sparse array nobody can replicate. Prefixing makes the key
	non-numeric-coercible by construction, the same reasoning
	Validate.itemId applies to inventory keys.
]]
function Match.playerKey(userId: number): string
	return `U{userId}`
end

return Match
