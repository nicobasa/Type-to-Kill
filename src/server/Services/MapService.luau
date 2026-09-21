--!strict
--[[
	The live map: one model cloned out of ServerStorage when a round needs it,
	plus the index of tagged parts inside it that SpawnService and
	LoadoutService ask for by kind.

	WHY A CLONE PER ROUND RATHER THAN SIX MAPS PARKED IN WORKSPACE

	A map that is only ever a clone cannot be damaged by the round it hosts:
	whatever was moved, broken or left lying around dies with
	Workspace.ActiveMap at unload, and the next round starts from the authored
	model again. Parking all six would also ship every map to every client on
	join to use one of them.

	WHY DISCOVERY IS BY TAG, AND WHY IT IS SCOPED TO THE CLONE

	Spawn points and pickup nodes are authored in Studio and found by
	CollectionService tag (Shared.Tags carries the authoring contract) -- never
	by instance name, and never by a coordinate written in a Luau file, which
	is a position nobody can drag in the viewport.

	The scoping is not optional. CollectionService:GetTagged is GLOBAL: it also
	returns the tagged parts of the five map TEMPLATES still sitting in
	ServerStorage.Maps, because a template carries the same tags its clone
	does. Unfiltered, a round on Dockyard would hand SpawnService spawn parts
	belonging to maps that are not loaded and place players at those authored
	coordinates -- empty air, or inside the live map's geometry. Every lookup
	here therefore filters on IsDescendantOf(activeModel).

	A MISSING MAP IS NOT FATAL. Every failure path logs and returns false,
	because the round loop has to keep cycling on a place whose Maps folder was
	never authored -- a server stuck before Lobby cannot tell anyone what is
	wrong.

	No per-player state and no listeners: this service owns one model and a few
	arrays of parts, so there is nothing to leak and nothing to clean up on
	PlayerRemoving. RoundService drives it through load()/unload(). Init() does
	one thing -- see it for why it cannot wait for Start().
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local MapCatalog = require(ReplicatedStorage.Shared.MapCatalog)
local Tags = require(ReplicatedStorage.Shared.Tags)

local log = Log.new("MapService")

local MAPS_FOLDER_NAME = "Maps"

-- PascalCase like every instance this project creates
-- (.claude/rules/model-naming-style.md). unload() sweeps Workspace for this
-- name, so it is the identity of the live map rather than a label on it.
local ACTIVE_MAP_NAME = "ActiveMap"

--[[
	The three kinds getSpawns() accepts: the two Match.TeamIds, plus the one
	every mode can fall back to. Constants rather than literals at the four
	sites that use them because FFA is also the fallback TARGET, and a fallback
	that misspells the key it falls back to fails silently, at spawn time, on
	one map.
]]
local KIND_RED = "Red"
local KIND_BLUE = "Blue"
local KIND_FFA = "FFA"

local activeModel: Instance? = nil
local activeMapId = ""

--[[
	Rebuilt on every load, emptied on every unload. Keyed by kind string rather
	than by named fields so getSpawns() can index it with the caller's argument
	directly -- a named-field type would need a cast or a three-way if to do
	the same thing.
]]
local spawns: { [string]: { BasePart } } = {}
local pickupNodes: { BasePart } = {}

local MapService = {}

--[[
	Every BasePart carrying `tag` INSIDE `model`.

	The IsDescendantOf filter is the entire point of this function -- see the
	header. It is cheap and it is load-time only, so there is no reason to be
	clever about it.
]]
local function collectTagged(tag: string, model: Instance): { BasePart }
	local found: { BasePart } = {}

	for _, instance in CollectionService:GetTagged(tag) do
		if not instance:IsDescendantOf(model) then
			continue
		end
		if instance:IsA("BasePart") then
			table.insert(found, instance)
		else
			-- A tag on a Model or a Folder is an authoring slip that otherwise
			-- vanishes without trace: the count simply comes out one short.
			log.warn(`{instance:GetFullName()} is tagged {tag} but is a {instance.ClassName} -- ignored`)
		end
	end

	-- GetTagged order is unspecified. Sorting by name makes "the third spawn"
	-- mean the same part in two consecutive rounds, which is the difference
	-- between a reproducible spawn bug and a haunted one.
	table.sort(found, function(a, b)
		return a.Name < b.Name
	end)

	return found
end

--[[
	Index a freshly parented map and say out loud what it is missing.

	Warnings, never errors: a map with no Red spawns still has to run a round
	(getSpawns falls back to FFA), and the author finds out from the output
	window rather than from a server that refused to start.
]]
local function indexMap(model: Instance, mapId: string)
	local red = collectTagged(Tags.SPAWN_RED, model)
	local blue = collectTagged(Tags.SPAWN_BLUE, model)
	local ffa = collectTagged(Tags.SPAWN_FFA, model)

	spawns = { [KIND_RED] = red, [KIND_BLUE] = blue, [KIND_FFA] = ffa }
	pickupNodes = collectTagged(Tags.PICKUP_NODE, model)

	if #ffa == 0 then
		log.warn(`{mapId} has no {Tags.SPAWN_FFA} parts -- FFA and the team fallback have nowhere to put anyone`)
	end
	if #red == 0 or #blue == 0 then
		log.warn(`{mapId} team spawns are Red={#red} Blue={#blue} -- the empty side falls back to {Tags.SPAWN_FFA}`)
	end

	log.info(`{mapId} loaded: Red={#red} Blue={#blue} FFA={#ffa} pickups={#pickupNodes}`)
end

--[[
	Destroy the live map, if there is one. Safe to call when there is not.

	Sweeps Workspace by name instead of only dropping our own reference.
	Workspace is authored in Studio and Rojo never touches it (ARCHITECTURE.md,
	"The map"), so a copy a designer left parented there survives a server
	restart and would otherwise sit inside the first map of the session --
	two overlapping sets of spawn points, in the same coordinates, with nothing
	in the log about it.
]]
function MapService.unload()
	local previous = activeModel
	if previous ~= nil then
		previous:Destroy()
		activeModel = nil
	end

	for _, child in Workspace:GetChildren() do
		if child.Name == ACTIVE_MAP_NAME then
			child:Destroy()
		end
	end

	activeMapId = ""
	-- The arrays hold references to parts that are now destroyed, and a stale
	-- spawn list is a player pivoted onto a part that is no longer in the world.
	spawns = {}
	pickupNodes = {}
end

--[[
	Clone `mapId` out of ServerStorage.Maps and make it the live map. Returns
	false, having logged why, when it cannot.

	Declared as a yielding call in the service contract: callers run it from
	Start() or a spawned thread, never from Init(). Nothing in the body yields
	today (Clone and a Parent assignment are both synchronous), and no caller
	may rely on that either way -- the round loop already paces MapLoading with
	Config.Round.MapLoadingMinDuration rather than with this function's timing.
]]
function MapService.load(mapId: string): boolean
	if not MapCatalog.exists(mapId) then
		log.error(`load("{mapId}") -- not an id in MapCatalog`)
		return false
	end

	local mapsFolder = ServerStorage:FindFirstChild(MAPS_FOLDER_NAME)
	if mapsFolder == nil then
		log.error(`ServerStorage.{MAPS_FOLDER_NAME} is missing -- author it in Studio, Rojo mounts scripts, not models`)
		return false
	end

	local template = mapsFolder:FindFirstChild(mapId)
	if template == nil then
		log.error(`ServerStorage.{MAPS_FOLDER_NAME}.{mapId} is missing -- MapCatalog lists a map this place lacks`)
		return false
	end
	-- Either container is fine: all this service does with the root is parent
	-- it and scope tag lookups to it. Anything else named like a map (a stray
	-- Script, a loose BasePart) is a mistake worth refusing.
	if not (template:IsA("Model") or template:IsA("Folder")) then
		log.error(`ServerStorage.{MAPS_FOLDER_NAME}.{mapId} is a {template.ClassName} -- expected a Model or a Folder`)
		return false
	end

	-- Only now, after every check that can fail: a load that fails because the
	-- new map is missing must not also take down the map that is up. Past this
	-- line the swap always completes, so no frame ever contains two maps.
	MapService.unload()

	local clone = template:Clone()
	clone.Name = ACTIVE_MAP_NAME
	-- Parent before indexing. CollectionService only reports instances that
	-- are in the DataModel, so a tag scan against an unparented clone finds
	-- nothing and the map comes up with zero spawns.
	clone.Parent = Workspace

	activeModel = clone
	activeMapId = mapId
	indexMap(clone, mapId)

	return true
end

--[[
	Whether there is a live map to spawn into right now.

	Checks the model is still parented rather than only that we hold a
	reference: a Destroy() from anywhere else -- a Studio edit during a Play
	test, a plugin -- leaves the reference pointing at a dead model, and
	"loaded" would then mean "spawn them into nothing".
]]
function MapService.isLoaded(): boolean
	local model = activeModel
	return model ~= nil and model.Parent ~= nil
end

--[[
	The live map's id, or "" when none is loaded -- the same convention the
	round replica's MapId field uses, so RoundService can write this through
	without translating a nil.
]]
function MapService.getActiveMapId(): string
	return activeMapId
end

--[[
	The spawn parts of `kind` ("Red" | "Blue" | "FFA") as a fresh array the
	caller may shuffle, sort or remove from: it is a copy, so doing any of that
	cannot quietly empty this service's index.

	Falls back to the FFA points when the loaded map has none of the kind asked
	for; the load-time warning already named the map, so this path stays quiet.
	SpawnService's job is to put the player somewhere, and refusing to answer
	here would turn one missing tag into a player in the void.
]]
function MapService.getSpawns(kind: string): { BasePart }
	if not MapService.isLoaded() then
		return {}
	end

	-- Annotated optional on purpose. A `{ [string]: { BasePart } }` indexer types
	-- as non-optional, so without this the nil branch below reads as dead code to
	-- the checker while being the live path at runtime for any kind but the three.
	local list: { BasePart }? = spawns[kind]
	if list == nil then
		-- Not one of the three kinds: a call-site typo, not a map problem.
		log.warn(`getSpawns("{kind}") -- not a spawn kind, answering with {KIND_FFA}`)
		list = spawns[KIND_FFA]
	elseif #list == 0 and kind ~= KIND_FFA then
		list = spawns[KIND_FFA]
	end

	return if list ~= nil then table.clone(list) else {}
end

--[[
	Every part tagged as a pickup node in the live map, as a fresh array.

	The `ItemId` attribute on each one is deliberately NOT read here: what a
	node is worth, and what to do with a node carrying an unknown id, is
	LoadoutService's decision (it owns pickups), and validating it in two
	places is two answers to one question.
]]
function MapService.getPickupNodes(): { BasePart }
	if not MapService.isLoaded() then
		return {}
	end
	return table.clone(pickupNodes)
end

--[[
	Destroy a Workspace.ActiveMap that was SAVED INTO THE PLACE, and say so.

	In Init(), not Start(), and the difference is the whole warning. Start()
	bodies are spawned in Priority order and run until their first yield, and
	RoundService (Priority 60) reaches `MapService.unload()` in its first cycle
	before its first `task.wait` -- so by the time this service's Start() ran,
	the stray would already have been swept, silently, and the one line that
	tells the author their place has a map committed into Workspace would never
	print. Init() is the only hook that provably runs before every Start().

	It also makes this sweep unable to hit a live map: nothing has loaded one
	yet during the Init phase, so the only ActiveMap that can exist here is a
	saved one. FindFirstChild and Destroy do not yield, so the no-yield rule on
	Init() holds.
]]
function MapService.Init()
	if Workspace:FindFirstChild(ACTIVE_MAP_NAME) ~= nil then
		log.warn(`a stray Workspace.{ACTIVE_MAP_NAME} was saved into this place -- destroying it`)
		MapService.unload()
	end
end

function MapService.Start()
	-- Before the first round rather than during it: a MapCatalog id with no
	-- model under ServerStorage.Maps is a Studio authoring problem, and the
	-- person who can fix it is reading the output window at boot, not fifteen
	-- seconds into a vote that just elected the map this place lacks.
	local mapsFolder = ServerStorage:FindFirstChild(MAPS_FOLDER_NAME)
	if mapsFolder == nil then
		log.error(`ServerStorage.{MAPS_FOLDER_NAME} is missing -- every round will run without a map`)
	else
		local missing: { string } = {}
		for _, definition in MapCatalog.LIST do
			if mapsFolder:FindFirstChild(definition.Id) == nil then
				table.insert(missing, definition.Id)
			end
		end
		-- Warn, not error: a vote can still elect one of these, and load()
		-- refuses it cleanly. This is the early notice, not the enforcement.
		if #missing > 0 then
			log.warn(`MapCatalog lists maps this place does not have: {table.concat(missing, ", ")}`)
		end
	end

	log.info("ready")
end

return MapService
