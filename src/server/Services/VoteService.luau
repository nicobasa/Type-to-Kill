--!strict
--[[
	The fifteen-second ballot: which map, which game mode (the ruleset), and
	which team mode.

	Three votes run side by side and a player holds at most one of each. Voting
	again MOVES that player's vote rather than adding a second -- which is why
	the votes live in {[Player]: choice} tables rather than in counters. A
	counter cannot express "move": to undo the previous vote it has to be told
	what that vote was, and the only honest place to keep that is the
	per-player table it was meant to replace.

	WHY THE TALLIES ARE DERIVED, NEVER INCREMENTED

	Every publish recounts from those tables. An incremental counter drifts the
	first time a voter vanishes mid-vote -- a player who leaves during Voting
	must stop counting, and undoing their increment needs their old vote
	anyway. The recount is over at most a server's worth of entries, once per
	accepted packet, which is cheaper than owning two copies of one truth and
	discovering later that one of them is stale.

	WHY endVote() FREEZES THE ANSWER

	Ties break at random, so resolving twice can legitimately disagree. If the
	round loop asked once and anything else asked again, the map that loads and
	the map that was announced would be two different maps. The answer is
	therefore computed exactly once, as the vote closes, and read back from
	then on. A caller who asks while the vote is still running gets a live
	answer and nothing is cached, because the vote is not over.

	RoundService drives the window: it calls beginVote() when Voting opens,
	endVote() when it closes, and getResult() at the start of MapLoading. This
	service never advances the state machine itself.

	Nothing here is secret. The ballot and the live tallies go into the round
	replica's Vote table, which every client receives -- that is the whole
	point, since the vote panel has to show the bars move during the fifteen
	seconds rather than only at the end.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local MapCatalog = require(ReplicatedStorage.Shared.MapCatalog)
local Match = require(ReplicatedStorage.Shared.Match)
local Net = require(ReplicatedStorage.Shared.Net)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local RoundService = require(script.Parent.RoundService)

local log = Log.new("VoteService")

--[[
	Its own generator rather than math.random. The global one is shared with
	every other module in this VM, so any math.randomseed anywhere -- a plugin,
	a package, a future service -- reshapes the ballot and re-rolls tie breaks.
	A fairness property that something else can perturb is not one you can
	reason about.
]]
local random = Random.new()

--[[
	One limiter per ballot, all on Config.RateLimit.Vote. Sharing a single one
	would make the votes interfere: picking a map, then a game mode, then a
	team mode is the normal way a player fills this screen in, and those clicks
	land well inside 250ms of each other, so a shared floor would silently drop
	the second one and the player would watch their vote fail to register.
	That is the "limit a real player can feel" Config.luau warns against, and
	it buys nothing -- a flooder is still bounded per packet kind, and each
	dropped packet still costs a table lookup and nothing else.
]]
local mapVoteLimit = RateLimiter.new(Config.RateLimit.Vote)

--[[
	The two mode ballots, which share a shape: a fixed list of options that
	never changes between rounds, one vote per player, and a tally published
	under its own key in the round replica's Vote table.

	Options come from Match's *_ORDER lists (lists, because a dictionary has no
	order and "the mode buttons moved between rounds" is a real bug from
	iterating one). The client builds the same lists from the same source, so
	the server and the panel always offer the same options.

	Stored as strings. Every value that gets in is matched against `options`
	first, so it is always a real id; getResult restates the type with one
	cast per ballot, and RoundService re-checks it with Match.is*Id anyway.
]]
type ModeBallot = {
	options: { string },
	votes: { [Player]: string },
	limit: RateLimiter.Limiter,
	-- The key in Round.Vote this ballot's tally is published under.
	tallyKey: string,
}

local gameModeBallot: ModeBallot = {
	options = table.clone(Match.GAME_MODE_ORDER) :: { any },
	votes = {},
	limit = RateLimiter.new(Config.RateLimit.Vote),
	tallyKey = "GameModeVotes",
}

local teamModeBallot: ModeBallot = {
	options = table.clone(Match.TEAM_MODE_ORDER) :: { any },
	votes = {},
	limit = RateLimiter.new(Config.RateLimit.Vote),
	tallyKey = "TeamModeVotes",
}

local VoteService = {}

-- The maps on offer this round. Replaced wholesale by beginVote, never edited
-- in place -- see the clone handed to the replica there.
local mapChoices: { string } = {}

local mapVotes: { [Player]: string } = {}

local accepting = false

-- The frozen result, nil until endVote() computes it. See the header.
type Result = {
	mapId: string,
	gameModeId: Match.GameModeId,
	teamModeId: Match.TeamModeId,
}
local resolved: Result? = nil

--[[
	Config.Voting.MapChoices DISTINCT maps.

	Shuffle a copy and take the front, rather than drawing at random and
	redrawing on a duplicate. Rejection sampling has no bound on how many draws
	one ballot costs, and it does not merely get slower as the ballot
	approaches the size of the catalog -- ask it for six maps out of six and
	the last slot redraws forever, because every candidate left is one it
	already holds. A shuffle cannot produce a duplicate at all, so the
	distinctness is structural instead of a loop condition someone has to
	trust.
]]
local function pickMapChoices(): { string }
	local pool: { string } = {}
	for _, definition in MapCatalog.LIST do
		table.insert(pool, definition.Id)
	end

	for index = #pool, 2, -1 do
		local swap = random:NextInteger(1, index)
		pool[index], pool[swap] = pool[swap], pool[index]
	end

	local wanted = math.min(Config.Voting.MapChoices, #pool)
	if wanted < Config.Voting.MapChoices then
		log.warn(`ballot holds {wanted} maps: MapCatalog has {#pool}, Config asks for {Config.Voting.MapChoices}`)
	end

	local choices: { string } = {}
	for index = 1, wanted do
		table.insert(choices, pool[index])
	end
	return choices
end

--[[
	Every ballot seeds every option at zero and counts only votes for options
	still on offer. Seeding matters: the panel draws a row per key, so a tally
	that gains its keys as votes arrive is a panel whose rows appear one at a
	time. Skipping unknown options matters for the mirror reason -- a key the
	client has no card for is a row it cannot draw.
]]
local function tally(options: { string }, votes: { [Player]: string }): { [string]: number }
	-- Annotated optional: a read of an option nobody seeded is genuinely nil,
	-- and the nil check below is what skips it (CLAUDE.md, the {[K]: V} trap).
	local counts: { [string]: number? } = {}
	for _, option in options do
		counts[option] = 0
	end
	for _, choice in votes do
		local current = counts[choice]
		if current ~= nil then
			counts[choice] = current + 1
		end
	end
	return counts :: { [string]: number }
end

local function tallyMaps(): { [string]: number }
	return tally(mapChoices, mapVotes)
end

local function publishModeBallot(ballot: ModeBallot)
	RoundService.writeVote({ [ballot.tallyKey] = tally(ballot.options, ballot.votes) })
end

--[[
	The option with the most votes, or nil when there is nothing to vote on.

	A tie is broken among THE TIED OPTIONS ONLY. The obvious one-liner --
	re-roll across the whole ballot when the top two are level -- hands the
	round to a map nobody voted for whenever two maps tie at four votes each,
	which players read, correctly, as the vote being ignored. With no votes at
	all every option ties at zero and this degrades to "pick any", which is the
	right answer for a ballot nobody filled in.

	The scan is options x voters. Three maps against a full server is under a
	hundred comparisons and it runs once per vote close, so an index kept in
	step with the tables would cost more to keep honest than it saves.
]]
local function resolveWinner<T>(ballot: { T }, cast: { [Player]: T }): T?
	local best = -1
	local tied: { T } = {}

	for _, option in ballot do
		local count = 0
		for _, choice in cast do
			if choice == option then
				count += 1
			end
		end

		if count > best then
			best = count
			table.clear(tied)
			table.insert(tied, option)
		elseif count == best then
			table.insert(tied, option)
		end
	end

	if #tied == 0 then
		return nil
	end
	return tied[random:NextInteger(1, #tied)]
end

local function resolve(): Result
	--[[
		Every local below is annotated because an inferred one widens the
		mode unions' singletons to plain `string`, and the Result promises the
		unions. The casts restate a contract that already holds -- every option
		on a mode ballot is an id from Match's ORDER list, and resolveWinner
		returns one of the options it was handed and nothing else -- they do
		not stand in for a check. A ballot is empty only if its ORDER list is,
		which falls back to the default.
	]]
	local gameWinner: Match.GameModeId? = resolveWinner(gameModeBallot.options, gameModeBallot.votes) :: any
	local gameModeId: Match.GameModeId = gameWinner or Match.DEFAULT_GAME_MODE
	local teamWinner: Match.TeamModeId? = resolveWinner(teamModeBallot.options, teamModeBallot.votes) :: any
	local teamModeId: Match.TeamModeId = teamWinner or Match.DEFAULT_TEAM_MODE

	local mapId = resolveWinner(mapChoices, mapVotes)
	if mapId ~= nil then
		return { mapId = mapId, gameModeId = gameModeId, teamModeId = teamModeId }
	end

	--[[
		No ballot at all: beginVote() never ran for this round. RoundService
		still has to be handed something it can load, and "" would send the
		loop into MapLoading against a map MapService cannot find, so any
		catalog map beats no map. The warn is the real signal -- this is a
		round-loop ordering bug, not a bad vote.
	]]
	if #MapCatalog.LIST == 0 then
		log.error("MapCatalog.LIST is empty -- there is no map to resolve to")
		return { mapId = "", gameModeId = gameModeId, teamModeId = teamModeId }
	end
	log.warn("resolving with no ballot -- beginVote() was never called for this round")
	return {
		mapId = MapCatalog.LIST[random:NextInteger(1, #MapCatalog.LIST)].Id,
		gameModeId = gameModeId,
		teamModeId = teamModeId,
	}
end

--[[
	Two gates, not one. `accepting` alone would hold the vote open forever if
	endVote() were ever missed; the state check alone would let a packet land in
	the gap between the vote closing and the state machine moving on. Either
	one failing is enough to drop the packet, which is the point.
]]
local function isOpen(): boolean
	return accepting and RoundService.getState() == "Voting"
end

local function onVoteMap(data: { mapId: string }, player: Player)
	--[[
		The limiter runs before every other check and before any logging.
		Anyone can send this packet, so the only response to a flood that does
		not cost more than the flood is to drop it having done no work -- the
		argument RateLimiter.luau's header makes in full.
	]]
	if not mapVoteLimit.allow(player) then
		return
	end
	if not isOpen() then
		return
	end

	-- ByteNet proved this is a string. That it names one of the maps actually
	-- on offer is ours to prove, or a crafted packet elects a map no player
	-- was ever shown -- or a map that is not in the catalog at all.
	if table.find(mapChoices, data.mapId) == nil then
		return
	end

	-- Re-sending the same vote is a no-op, not a write: SetValues would cost a
	-- replication packet to tell every client nothing changed.
	if mapVotes[player] == data.mapId then
		return
	end

	mapVotes[player] = data.mapId
	RoundService.writeVote({ MapVotes = tallyMaps() })
end

local function onVoteModeBallot(ballot: ModeBallot, modeId: string, player: Player)
	if not ballot.limit.allow(player) then
		return
	end
	if not isOpen() then
		return
	end

	-- ByteNet proved this is a string. That it is an option on THIS ballot is
	-- ours to prove, or a crafted packet elects a mode nobody was shown.
	if table.find(ballot.options, modeId) == nil or ballot.votes[player] == modeId then
		return
	end

	ballot.votes[player] = modeId
	publishModeBallot(ballot)
end

local function onPlayerRemoving(player: Player)
	--[[
		A leaver's vote stops counting immediately. Two reasons, and the second
		is the one that bites: a player who votes and disconnects would
		otherwise still be picking the map for the players who stayed, and a
		{[Player]: T} that nothing clears pins every Player instance that has
		ever been in the server.
	]]
	local hadMapVote = mapVotes[player] ~= nil
	mapVotes[player] = nil

	-- Republish only what actually moved, and only while a ballot is live --
	-- after the close the published tallies are a finished result the results
	-- panel may still be showing, and the cleared tables would zero it.
	if accepting and hadMapVote then
		RoundService.writeVote({ MapVotes = tallyMaps() })
	end

	for _, ballot in { gameModeBallot, teamModeBallot } do
		local hadVote = ballot.votes[player] ~= nil
		ballot.votes[player] = nil
		if accepting and hadVote then
			publishModeBallot(ballot)
		end
	end
end

--[[
	Opens a fresh ballot: new maps, every previous vote discarded.

	Clearing here as well as in endVote() is what makes a missed close
	harmless. A round that ends abnormally -- the last player leaves and the
	loop falls back to Lobby -- never gets its endVote(), and stale votes from
	players who are no longer here would otherwise decide the next map.
]]
function VoteService.beginVote()
	mapChoices = pickMapChoices()
	table.clear(mapVotes)
	table.clear(gameModeBallot.votes)
	table.clear(teamModeBallot.votes)
	resolved = nil
	accepting = true

	--[[
		One write, every field: the panel needs the choices and all three
		tallies to draw anything, and separate writes would let it draw from a
		half-built vote table.

		MapChoices is a CLONE. A Replica holds the table it is handed rather
		than a copy of it (DataService.luau's note on `Data = profile.Data`), so
		passing the live ballot would make any later edit to it a silent change
		to replicated state that never replicates.
	]]
	RoundService.writeVote({
		MapChoices = table.clone(mapChoices),
		MapVotes = tallyMaps(),
		[gameModeBallot.tallyKey] = tally(gameModeBallot.options, gameModeBallot.votes),
		[teamModeBallot.tallyKey] = tally(teamModeBallot.options, teamModeBallot.votes),
	})
end

--[[
	Closes the ballot and freezes the result (see the header on why a tie must
	not be re-rolled), then drops the per-player tables: they are keyed by
	Player, and nothing downstream needs them once the answer exists.

	The published tallies are deliberately left standing. They are the final
	count, the results panel may still be reading them, and the next
	beginVote() overwrites them anyway.
]]
function VoteService.endVote()
	if not accepting then
		-- Already closed, or never opened. Re-closing must not re-roll a tie
		-- that has already been announced to everyone.
		return
	end
	accepting = false

	if resolved == nil then
		resolved = resolve()
	end

	table.clear(mapVotes)
	table.clear(gameModeBallot.votes)
	table.clear(teamModeBallot.votes)
end

--[[
	The winning map id, game mode id and team mode id. Random among the tied
	options only.
]]
function VoteService.getResult(): (string, Match.GameModeId, Match.TeamModeId)
	local frozen = resolved
	if frozen ~= nil then
		return frozen.mapId, frozen.gameModeId, frozen.teamModeId
	end

	local result = resolve()

	--[[
		Freeze on the FIRST ask that lands after the vote stopped being open,
		not only inside endVote(). The round loop calls both, and nothing in
		the contract fixes their order: ask-then-close would otherwise load one
		tie break and freeze a different one for everybody who asked later.
		Tying the freeze to "can a vote still change this?" makes the two
		orders identical, which is the only version of this that survives
		someone reordering two lines in RoundService.

		While the vote IS open nothing is cached, because the answer can still
		legitimately change -- that is what makes it the wrong one to keep.
	]]
	if not isOpen() then
		resolved = result
	end

	return result.mapId, result.gameModeId, result.teamModeId
end

--[[
	A COPY of the ballot. Handing out the live table lets a caller sort or trim
	it in place, and the ballot the server validates votes against would then
	differ from the one it published to every client, with no write anywhere to
	blame it on.
]]
function VoteService.getMapChoices(): { string }
	return table.clone(mapChoices)
end

function VoteService.Init()
	Net.voteMap.listen(function(data, player)
		if player ~= nil then
			onVoteMap(data, player)
		end
	end)

	Net.voteGameMode.listen(function(data, player)
		if player ~= nil then
			onVoteModeBallot(gameModeBallot, data.modeId, player)
		end
	end)

	Net.voteTeamMode.listen(function(data, player)
		if player ~= nil then
			onVoteModeBallot(teamModeBallot, data.modeId, player)
		end
	end)

	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

function VoteService.Start()
	log.info("ready")
end

return VoteService
