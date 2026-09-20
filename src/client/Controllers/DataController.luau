--!strict
--[[
	Client side of the data layer.

	Replica hands you a plain table (replica.Data) that the server keeps in sync,
	plus listeners that fire when a path changes. That's the whole model.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Replica = require(ReplicatedStorage.ReplicaClient)

local log = Log.new("DataController")

local player = Players.LocalPlayer

local DataController = {
	Priority = 100,
}

local dataReplica: any = nil
local readyWaiters: { thread } = {}

function DataController.Init()
	--[[
		Register in Init, NOT Start. OnNew does not replay replicas that already
		arrived -- if the replica lands before this listener exists, you miss it
		permanently and silently.

		Main.client.luau calls Replica.RequestData() only after every Init() has
		run, so this listener is guaranteed live before the server sends anything.
		That ordering is the entire reason Init and Start are separate phases.
	]]
	Replica.OnNew("PlayerData", function(replica)
		-- Tags are set once server-side at creation and never change.
		if replica.Tags.UserId ~= player.UserId then
			return -- not ours (won't happen today; cheap guard if that changes)
		end

		dataReplica = replica
		log.info("player data received")

		for _, thread in readyWaiters do
			task.spawn(thread)
		end
		table.clear(readyWaiters)
	end)
end

--[[
	Yields until the replica has arrived. Returns false on timeout.

	This is the per-player readiness gate, and it replaces a global "wait for the
	server to boot" flag. It's better for a specific reason: "the server booted"
	and "MY data is here" are different facts. A player joining a 40-minute-old
	server would sail straight past a global flag that flipped ages ago and read
	an empty table. The gap between those two facts is exactly where the "coins
	show 0 for half a second" bug lives.
]]
function DataController.await(timeout: number?): boolean
	if dataReplica ~= nil then
		return true
	end

	local thread = coroutine.running()
	table.insert(readyWaiters, thread)

	local timedOut = false
	if timeout ~= nil then
		task.delay(timeout, function()
			if dataReplica ~= nil then
				return -- already resumed by OnNew; must not resume twice
			end
			local index = table.find(readyWaiters, thread)
			if index ~= nil then
				table.remove(readyWaiters, index)
				timedOut = true
				task.spawn(thread)
			end
		end)
	end

	coroutine.yield()
	return not timedOut
end

-- The replicated table. nil until await() returns.
function DataController.getData(): any?
	return if dataReplica ~= nil then dataReplica.Data else nil
end

local function readPath(root: any, path: { string | number }): any
	local current: any = root
	for _, key in path do
		if current == nil then
			return nil
		end
		current = current[key]
	end
	return current
end

--[[
	True when one path is a prefix of the other (either direction).

	Both directions matter, and for different reasons:
	  {"Settings"} vs {"Settings","MusicEnabled"} -- a write AT or ABOVE us: our
	      value was replaced wholesale.
	  {"Inventory","Sword"} vs {"Inventory"} -- a write BELOW us: our table's
	      contents changed, though the table itself is the same object.
]]
local function pathsIntersect(a: { string | number }, b: { string | number }): boolean
	for i = 1, math.min(#a, #b) do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

--[[
	Fires when a path changes, AND immediately with the current value -- so a UI
	binding is one call with no "connect, then also read once" boilerplate, and
	no first frame showing the Studio placeholder text.

		DataController.observe({"Coins"}, function(coins)
			label.Text = `{coins}`
		end)

	Built on OnChange, NOT OnSet, and that is load-bearing. OnSet is keyed on an
	exact concatenated path string and is fired ONLY by Replica:Set
	(ReplicaClient.luau:393). SetValues, TableInsert and TableRemove fire the
	changed_listeners signal and nothing else. An OnSet-based observer is
	therefore blind to three of the four write actions, and blind to nested
	writes under the path it watches -- it just never fires, with no error. That
	is not a defect you find by reading the call site.

	Cost: every observer is consulted on every change to the replica, rather than
	a single hash lookup. For player data that is a handful of comparisons on a
	human-paced event. Correctness is worth more here.
]]
function DataController.observe(path: { string | number }, listener: (value: any, old: any?) -> ())
	task.spawn(function()
		if not DataController.await(30) then
			log.warn(`observe({table.concat(path :: any, ".")}) timed out waiting for data`)
			return
		end

		local last: any = readPath(dataReplica.Data, path)

		dataReplica:OnChange(function(_action: string, changedPath: { string | number })
			if not pathsIntersect(path, changedPath) then
				return
			end

			local current: any = readPath(dataReplica.Data, path)

			--[[
				Suppress no-op fires for scalars -- SetValues on a sibling key
				intersects us but leaves our value alone.

				Tables are deliberately exempt: an in-place child write keeps the
				same table object, so `current == last` is true even though the
				contents just changed. Comparing identity there would reintroduce
				the exact silence this function exists to remove.
			]]
			if current == last and type(current) ~= "table" then
				return
			end

			local old: any = last
			last = current
			listener(current, old)
		end)

		listener(last, nil)
	end)
end

return DataController
