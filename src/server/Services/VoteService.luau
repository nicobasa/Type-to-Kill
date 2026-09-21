--!strict
--[[
	The fifteen-second ballot: which map, and which mode.

	Two votes run side by side and a player holds at most one of each. Voting
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
	One limiter per ballot, both on Config.RateLimit.Vote. Sharing a single one
	would make the two votes interfere: picking a map and then a mode is the
	normal way a player fills this screen in, and those two clicks land well
	inside 250ms of each other, so a shared floor would silently drop the
	second one and the player would watch their mode vote fail to register.
	That is the "limit a real player can feel" Config.luau warns against, and
	it buys nothing -- a flooder is still bounded per packet kind, and each
	dropped packet still costs a table lookup and nothing else.
]]
local mapVoteLimit = RateLimiter.new(Config.RateLimit.Vote)
local modeVoteLimit = RateLimiter.new(Config.RateLimit.Vote)

--[[
	The mode ballot never changes, so it is built once rather than per round.

	It is Match.MODE_ORDER (a list, because a dictionary has no order and "the
	mode buttons moved between rounds" is a real bug from iterating one) capped
	at Config.Voting.MaxModeChoices, which is how many columns the vote panel
	has. A fourth mode past that cap would be one the server happily accepts
	votes for and no player can see to vote for, so the cap is applied to the
	ballot the SERVER enforces too, not just to the UI.
]]
local MODE_BALLOT: { Match.GameModeId } = {}
for index = 1, math.min(Config.Voting.MaxModeChoices, #Match.MODE_ORDER) do
	table.insert(MODE_BALLOT, Match.MODE_ORDER[index])
end
if #MODE_BALLOT < #Match.MODE_ORDER then
	log.warn(`{#Match.MODE_ORDER - #MODE_BALLOT} mode(s) off the ballot -- MaxModeChoices is {#MODE_BALLOT}`)
end

local VoteService = {}

-- The maps on offer this round. Replaced wholesale by beginVote, never edited
-- in place -- see the clone handed to the replica there.
local mapChoices: { string } = {}

local mapVotes: { [Player]: string } = {}
local modeVotes: { [Player]: Match.GameModeId } = {}

local accepting = false

-- The frozen result, nil until endVote() computes it. See the header.
local resolvedMapId: string? = nil
local resolvedModeId: Match.GameModeId? = nil

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
	Both ballots seed every option at zero and count only votes for options
	still on offer. Seeding matters: the panel draws a row per key, so a tally
	that gains its keys as votes arrive is a panel whose rows appear one at a
	time. Skipping unknown options matters for the mirror reason -- a key the
	client has no card for is a row it cannot draw.
]]
local function tallyMaps(): { [string]: number }
	local counts: { [string]: number } = {}
	for _, mapId in mapChoices do
		counts[mapId] = 0
	end
	for _, mapId in mapVotes do
		local current = counts[mapId]
		if current ~= nil then
			counts[mapId] = current + 1
		end
	end
	return counts
end

local function tallyModes(): { [string]: number }
	local counts: { [string]: number } = {}
	for _, modeId in MODE_BALLOT do
		counts[modeId] = 0
	end
	for _, modeId in modeVotes do
		local current = counts[modeId]
		if current ~= nil then
			counts[modeId] = current + 1
		end
	end
	return counts
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

local function resolve(): (string, Match.GameModeId)
	-- MODE_BALLOT is empty only if Match.MODE_ORDER is, which the type system
	-- cannot rule out and which would otherwise leave the round with no mode.

	--[[
		Every local below is annotated because an inferred one widens
		GameModeId's two singletons to plain `string`, and the return promises
		the union. The cast restates a contract that already holds; it does not
		stand in for a check.

		resolveWinner returns an element of the ballot it was handed and nothing
		else, and MODE_BALLOT is `{ GameModeId }` by construction. Luau still
		widens GameModeId's two singletons to `string` across the generic --
		instantiating `T` into a fresh `{ T }` loses literal types (verified
		against luau-lsp on a four-line reduction of resolveWinner).
	]]
	local fallbackMode: Match.GameModeId = Match.DEFAULT_MODE
	local winner: Match.GameModeId? = resolveWinner(MODE_BALLOT, modeVotes) :: Match.GameModeId?
	local modeId: Match.GameModeId = winner or fallbackMode

	local mapId = resolveWinner(mapChoices, mapVotes)
	if mapId ~= nil then
		return mapId, modeId
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
		return "", modeId
	end
	log.warn("resolving with no ballot -- beginVote() was never called for this round")
	return MapCatalog.LIST[random:NextInteger(1, #MapCatalog.LIST)].Id, modeId
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

local function onVoteMode(data: { modeId: string }, player: Player)
	if not modeVoteLimit.allow(player) then
		return
	end
	if not isOpen() then
		return
	end

	--[[
		Matched against the ballot by iteration rather than table.find so the
		value stored is the one FROM MODE_BALLOT: it is a GameModeId by
		construction, where the packet's field is only a string. That keeps the
		mode a typed value all the way to getResult with no cast standing in
		for a check.
	]]
	local chosen: Match.GameModeId? = nil
	for _, modeId: Match.GameModeId in MODE_BALLOT do
		if modeId == data.modeId then
			chosen = modeId
			break
		end
	end
	if chosen == nil or modeVotes[player] == chosen then
		return
	end

	modeVotes[player] = chosen
	RoundService.writeVote({ ModeVotes = tallyModes() })
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
	local hadModeVote = modeVotes[player] ~= nil
	mapVotes[player] = nil
	modeVotes[player] = nil

	-- Republish only what actually moved, and only while a ballot is live --
	-- after the close the published tallies are a finished result the results
	-- panel may still be showing, and the cleared tables would zero it.
	if not accepting then
		return
	end
	if hadMapVote then
		RoundService.writeVote({ MapVotes = tallyMaps() })
	end
	if hadModeVote then
		RoundService.writeVote({ ModeVotes = tallyModes() })
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
	table.clear(modeVotes)
	resolvedMapId = nil
	resolvedModeId = nil
	accepting = true

	--[[
		One write, all three fields: the panel needs the choices and both
		tallies to draw anything, and three separate writes would let it draw
		twice from a half-built vote table.

		MapChoices is a CLONE. A Replica holds the table it is handed rather
		than a copy of it (DataService.luau's note on `Data = profile.Data`), so
		passing the live ballot would make any later edit to it a silent change
		to replicated state that never replicates.
	]]
	RoundService.writeVote({
		MapChoices = table.clone(mapChoices),
		MapVotes = tallyMaps(),
		ModeVotes = tallyModes(),
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

	if resolvedMapId == nil or resolvedModeId == nil then
		resolvedMapId, resolvedModeId = resolve()
	end

	table.clear(mapVotes)
	table.clear(modeVotes)
end

--[[
	The winning map id and mode id. Random among the tied options only.
]]
function VoteService.getResult(): (string, Match.GameModeId)
	if resolvedMapId ~= nil and resolvedModeId ~= nil then
		return resolvedMapId, resolvedModeId
	end

	-- Annotated for the same reason resolve() annotates its own: an inferred
	-- local drops GameModeId back to a widened string, and the freeze below
	-- writes it into resolvedModeId, which is typed.
	local mapId: string, modeId: Match.GameModeId = resolve()

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
		resolvedMapId, resolvedModeId = mapId, modeId
	end

	return mapId, modeId
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

	Net.voteMode.listen(function(data, player)
		if player ~= nil then
			onVoteMode(data, player)
		end
	end)

	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

function VoteService.Start()
	log.info("ready")
end

return VoteService
