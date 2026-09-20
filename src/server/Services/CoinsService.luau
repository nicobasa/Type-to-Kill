--!strict
--[[
	The Coins balance. Every change is a delta.

	There is deliberately no set(). An absolute setter is only safe if every
	caller, forever, avoids yielding between reading the balance and writing
	it back -- an invariant that is invisible at the call site and that
	nothing enforces. Fire a purchase remote twice in one frame against a
	set()-based API and both handlers read 100, both write 90, and the player
	got two items for one price. add()/trySpend() do the read-compute-write
	inside themselves in one yield-free slice, so that window cannot exist.
	The only legitimate absolute write is the dev console's, which already
	validates and already leaves an audit trail (DevService.luau:287).

	No per-player state, no Init(), no Priority. This service registers no
	listeners and owns no {[Player]: T} table, so there is nothing to leak
	and nothing to clean up on PlayerRemoving -- every function reads
	DataService.getData(player) fresh and fails soft if it's nil.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local DataService = require(script.Parent.DataService)
local Log = require(ReplicatedStorage.Shared.Log)
local Validate = require(ServerStorage.Modules.Validate)

local log = Log.new("CoinsService")

--[[
	MAX_COINS + MAX_GRANT = 1.001e15, safely under 2^53 (~9.007e15) --
	float64's exact-integer ceiling -- so every intermediate sum below stays
	exact. MAX_COINS is deliberately NOT 2^53 itself: at the precision limit
	a sum has already lost precision by the time a check could catch it, and
	past it n + 1 == n, so coins would silently stop increasing forever with
	no error. Any game legitimately reaching 1e15 coins has a balance bug;
	clamping here surfaces that instead of hiding it.
]]
local MAX_COINS = 1e15
local MAX_GRANT = 1e12

local CoinsService = {}

--[[
	The current balance, or nil if this player's data is not loaded (still
	loading, or already left).

	READ-ONLY. Never compute a new balance from this and write it back --
	that reopens exactly the stale-read window add()/trySpend() exist to
	close. For HUD, telemetry and gating decisions only.
]]
function CoinsService.get(player: Player): number?
	local data = DataService.getData(player)
	return if data ~= nil then data.Coins else nil
end

--[[
	Grant coins. `amount` must be a positive finite integer <= MAX_GRANT.
	The result is clamped at MAX_COINS.

	Returns true if the grant was accepted and applied (clamping still counts
	as applied). Returns false only if the amount was rejected or the player
	has no loaded data -- in both cases the balance is untouched.
]]
function CoinsService.add(player: Player, amount: number): boolean
	if not Validate.amount(amount, MAX_GRANT) then
		log.warn(`add() on {player.Name} with an invalid amount -- rejected`)
		return false
	end

	local data = DataService.getData(player)
	if data == nil then
		log.debug(`add() on {player.Name} with no loaded data -- dropped`)
		return false
	end

	local newCoins = math.min(data.Coins + amount, MAX_COINS)
	if newCoins == data.Coins then
		-- Already at the cap. Writing would cost a replication packet to
		-- change nothing. A runaway grant loop should still be visible,
		-- hence the line rather than a silent return.
		log.debug(`add() on {player.Name} is capped at MAX_COINS -- no write`)
		return true
	end

	DataService.set(player, { "Coins" }, newCoins)
	return true
end

--[[
	Deduct `cost` coins if the player can afford them. `cost` must be a
	positive finite integer <= MAX_GRANT.

	Returns true only if the deduction happened. Never accepts a
	caller-supplied balance -- it reads inside itself, and that is the entire
	guarantee.
]]
function CoinsService.trySpend(player: Player, cost: number): boolean
	if not Validate.amount(cost, MAX_GRANT) then
		log.warn(`trySpend() on {player.Name} with an invalid cost -- rejected`)
		return false
	end

	local data = DataService.getData(player)
	if data == nil then
		log.debug(`trySpend() on {player.Name} with no loaded data -- dropped`)
		return false
	end

	if data.Coins < cost then
		return false
	end

	DataService.set(player, { "Coins" }, data.Coins - cost)
	return true
end

function CoinsService.Start()
	log.info("ready")
end

return CoinsService
