--!strict
--[[
	The Inventory: a map of item id -> count.

	There is no item catalog and no set(). Any string is a legal id provided
	its SHAPE is legal (Validate.itemId) -- the shape rules are not politeness,
	they are what keeps Inventory replicable at all. Counts change only by
	delta, for the same reason CoinsService has no set(): an absolute setter is
	only safe if every caller, forever, avoids yielding between reading the
	count and writing it back -- an invariant nothing enforces. add()/tryRemove()
	do the read-compute-write inside themselves in one yield-free slice, so that
	window cannot exist.

	Removal DELETES the key. It never writes 0. A zero-count tombstone is
	invisible in game and permanent on disk: it costs DataStore bytes against
	the 4MB key limit and replication bandwidth on every session, forever, for
	an item the player does not have.

	The dev console can plant a non-number into an Inventory key: it only
	type-pins a field once TEMPLATE has seeded it with a scalar, and Inventory
	entries have none until this service writes one, so `Inventory.Sword`
	typed as a string is one console click away -- the `{[string]: number}`
	annotation on data.Inventory is a promise the console can break. Every read
	of a stored count is guarded (`type(raw) == "number" and raw == raw`) and
	treats anything else as absent (0) rather than trusting it. The next add()
	then overwrites it with a real count, self-healing the same way the
	dev-console divergence on Level/Experience is documented at
	LevelService.luau:11-15.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local DataService = require(script.Parent.DataService)
local Log = require(ReplicatedStorage.Shared.Log)
local Validate = require(ServerStorage.Modules.Validate)

local log = Log.new("InventoryService")

local MAX_ITEM_COUNT = 1e12
local MAX_ITEM_GRANT = 1e9

local InventoryService = {}

--[[
	How many of `itemId` the player holds.

	nil and 0 mean DIFFERENT things and callers must not conflate them:
	  nil = cannot answer (no loaded data, or a malformed id)
	  0   = answered: the player does not hold this item
	Use has() unless you actually need the number.
]]
function InventoryService.getCount(player: Player, itemId: string): number?
	if not Validate.itemId(itemId) then
		log.warn(`getCount() on {player.Name} with a malformed item id -- rejected`)
		return nil
	end
	local data = DataService.getData(player)
	if data == nil then
		return nil
	end
	--[[
		The dev console can write a non-number (even a boolean) into a key the
		player does not hold yet -- DevService's typeMatches permits any type
		when the existing value is nil, which is exactly a fresh Inventory key.
		A guarded read treats a corrupted entry as "not held" rather than
		propagating the wrong type into a caller's arithmetic/comparison, the
		same treatment LevelService gives profile data it did not write itself.
	]]
	local raw = data.Inventory[itemId]
	return if type(raw) == "number" and raw == raw then raw else 0
end

--[[
	Whether the player holds at least `count` of `itemId`. `count` defaults to
	1. Returns false -- never nil -- for unloaded data or a malformed id, so a
	caller cannot accidentally treat "unknown" as "yes".
]]
function InventoryService.has(player: Player, itemId: string, count: number?): boolean
	local wanted = count or 1
	if not Validate.amount(wanted, MAX_ITEM_GRANT) then
		log.warn(`has() on {player.Name} with an invalid count -- rejected`)
		return false
	end
	local held = InventoryService.getCount(player, itemId)
	return held ~= nil and held >= wanted
end

--[[
	Grant `count` of `itemId`, creating the key if the player has none.
	`count` must be a positive finite integer <= MAX_ITEM_GRANT.
	The stack is clamped at MAX_ITEM_COUNT.

	Returns true if the grant was accepted and applied (clamping counts as
	applied); false if the id or count was rejected, or the data is not loaded.
]]
function InventoryService.add(player: Player, itemId: string, count: number): boolean
	if not Validate.itemId(itemId) then
		log.warn(`add() on {player.Name} with a malformed item id -- rejected`)
		return false
	end
	if not Validate.amount(count, MAX_ITEM_GRANT) then
		log.warn(`add() on {player.Name} with an invalid count -- rejected`)
		return false
	end

	local data = DataService.getData(player)
	if data == nil then
		log.debug(`add() on {player.Name} with no loaded data -- dropped`)
		return false
	end

	--[[
		Guarded, not `data.Inventory[itemId] or 0`: the dev console can plant a
		non-number here for a key the player never held (see getCount's
		comment). An unguarded read throws "attempt to perform arithmetic on
		string" straight into whatever gameplay code called add() -- a pickup
		handler, a shop -- aborting it mid-transaction. Treating a corrupt
		entry as "not held" lets this write overwrite it back to a clean number.
	]]
	local raw = data.Inventory[itemId]
	local held = if type(raw) == "number" and raw == raw then raw else 0
	local newCount = math.min(held + count, MAX_ITEM_COUNT)
	if newCount == held then
		-- Already at the cap. Writing would cost a replication packet to
		-- change nothing. A runaway grant loop should still be visible, hence
		-- the line rather than a silent return.
		log.debug(`add() on {player.Name} is capped at MAX_ITEM_COUNT for {itemId} -- no write`)
		return true
	end

	--[[
		Writing a key that does not exist yet is fine: the path's parent
		(Inventory) is guaranteed present by TEMPLATE + Reconcile, and Replica
		does not auto-vivify -- it only requires that the parent table exists,
		which it does.
	]]
	DataService.set(player, { "Inventory", itemId }, newCount)
	return true
end

--[[
	Remove `count` of `itemId` if the player has that many.
	Returns true only if the removal happened.
	When the stack reaches exactly 0 the KEY IS DELETED, not set to 0.
]]
function InventoryService.tryRemove(player: Player, itemId: string, count: number): boolean
	if not Validate.itemId(itemId) then
		log.warn(`tryRemove() on {player.Name} with a malformed item id -- rejected`)
		return false
	end
	if not Validate.amount(count, MAX_ITEM_GRANT) then
		log.warn(`tryRemove() on {player.Name} with an invalid count -- rejected`)
		return false
	end

	local data = DataService.getData(player)
	if data == nil then
		log.debug(`tryRemove() on {player.Name} with no loaded data -- dropped`)
		return false
	end

	-- Guarded for the same reason as add(): a dev-console-planted non-number
	-- must read as "not held", not throw "attempt to compare string with number".
	local raw = data.Inventory[itemId]
	local held = if type(raw) == "number" and raw == raw then raw else 0
	if held < count then
		return false
	end

	local newCount = held - count
	if newCount == 0 then
		--[[
			nil DELETES the key -- it does not write nil. Replica sends the
			value as a positional RemoteEvent argument (ReplicaServer.luau:356)
			rather than packing it into a table, and the client binds it as a
			named parameter (ReplicaClient.luau:718), so an explicit nil and a
			dropped trailing nil are indistinguishable there: both delete.

			setValues CANNOT express this. `{ [id] = nil }` IS `{}` at
			construction, so its pairs() loop (ReplicaServer.luau:376) never
			sees the key. Deletion must go through set().
		]]
		DataService.set(player, { "Inventory", itemId }, nil)
	else
		DataService.set(player, { "Inventory", itemId }, newCount)
	end
	return true
end

function InventoryService.Start()
	log.info("ready")
end

return InventoryService
