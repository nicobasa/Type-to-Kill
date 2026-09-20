--!strict
--[[
	Two-phase lifecycle loader. Replaces a Service Locator.

	This loader does NOT resolve dependencies -- `require` already does that,
	and it does it with real types. A locator's `Get("DataService")` returns
	`any`, and in strict mode one `any` silently disables typechecking for
	everything downstream of it. So: require your dependencies directly at the
	top of the file, and let this handle only lifecycle ordering.

	  1. require every *Service / *Controller ModuleScript (bodies run)
	  2. Init()  -- sequential, sorted by Priority desc, MUST NOT YIELD
	  3. Start() -- spawned in parallel, may yield

	Invariant: every module body and every Init() has completed before any
	Start() runs. That is what lets Start() touch anything without ordering
	anxiety.

	Cyclic requires: Luau throws on these at load, so they self-detect. When
	two modules genuinely need each other, defer one side -- the annotation is
	erased at runtime, so no cycle exists, but types still resolve:

		local Other: typeof(require(script.Parent.OtherService)) = nil :: any
		function MyService.Init()
			Other = require(script.Parent.OtherService)
		end
]]

local Log = require(script.Parent.Log)

export type LifecycleModule = {
	-- Higher runs first. Default 0. Orders Init only; Start is always parallel.
	Priority: number?,
	Init: (() -> ())?,
	Start: (() -> ())?,
}

type Entry = {
	name: string,
	instance: ModuleScript,
	module: LifecycleModule,
}

local log = Log.new("Loader")

local Loader = {}

-- Modules that have already been through the lifecycle. `require` caches, so a
-- second load of the same container hands back the SAME table and would run
-- Init() on it twice -- which turns any non-idempotent Init into a silent
-- corruption (e.g. `store = store.Mock` nils the store on the second pass).
-- Guarding here means that bug can only ever happen once, not once per module.
local initialized: { [ModuleScript]: true } = {}

-- Convention over configuration: only *Service / *Controller participate in
-- the lifecycle. Plain modules stay inert and are required directly by
-- whoever needs them.
local function isLifecycleModule(instance: Instance): boolean
	if not instance:IsA("ModuleScript") then
		return false
	end
	return string.match(instance.Name, "Service$") ~= nil or string.match(instance.Name, "Controller$") ~= nil
end

local function collect(containers: { Instance }): { Entry }
	local entries: { Entry } = {}

	for _, container in containers do
		for _, descendant in container:GetDescendants() do
			if not isLifecycleModule(descendant) then
				continue
			end

			local ok, result = pcall(require, descendant :: ModuleScript)
			if not ok then
				-- A module that cannot load is fatal. Fail loudly at boot rather
				-- than limping along with half a game.
				error(`[Loader] require failed: {descendant:GetFullName()}\n{result}`, 0)
			end

			if type(result) ~= "table" then
				error(`[Loader] {descendant:GetFullName()} must return a table, got {type(result)}`, 0)
			end

			if initialized[descendant :: ModuleScript] then
				-- Almost always an orphaned instance from an older project.json
				-- that Rojo no longer manages but never deleted.
				log.warn(`{descendant:GetFullName()} already loaded -- skipping. Is a stale copy still in the place?`)
				continue
			end
			initialized[descendant :: ModuleScript] = true

			table.insert(entries, {
				name = descendant.Name,
				instance = descendant :: ModuleScript,
				module = result :: LifecycleModule,
			})
		end
	end

	-- Deterministic order: Priority desc, then name. GetDescendants order is
	-- not guaranteed stable, so never rely on it.
	table.sort(entries, function(a, b)
		local priorityA = a.module.Priority or 0
		local priorityB = b.module.Priority or 0
		if priorityA ~= priorityB then
			return priorityA > priorityB
		end
		return a.name < b.name
	end)

	return entries
end

local function runInit(entry: Entry)
	local init = entry.module.Init
	if init == nil then
		return
	end

	local thread = coroutine.create(init)
	local ok, err = coroutine.resume(thread)

	if not ok then
		error(`[Loader] {entry.name}.Init() errored: {err}\n{debug.traceback(thread)}`, 0)
	end

	-- The enforcement that makes the contract real. Without it, one stray
	-- WaitForChild in an Init silently reorders the whole boot and you debug
	-- it at 2am.
	if coroutine.status(thread) ~= "dead" then
		error(`[Loader] {entry.name}.Init() yielded -- Init must be synchronous. Move blocking work to Start().`, 0)
	end
end

local function runStart(entry: Entry)
	local start = entry.module.Start
	if start == nil then
		return
	end

	-- Spawned, so one slow Start never blocks another.
	task.spawn(function()
		local ok, err = xpcall(start, debug.traceback)
		if not ok then
			log.error(`{entry.name}.Start() errored: {err}`)
		end
	end)
end

--[[
	Loads every lifecycle module found under `containers`.
	Call exactly once per context, from the bootstrap script.
]]
function Loader.load(containers: { Instance })
	local startClock = os.clock()

	local entries = collect(containers)

	for _, entry in entries do
		runInit(entry)
	end
	log.debug(`Init phase complete ({#entries} modules, {math.floor((os.clock() - startClock) * 1000)}ms)`)

	for _, entry in entries do
		runStart(entry)
	end

	log.info(`loaded {#entries} modules in {math.floor((os.clock() - startClock) * 1000)}ms`)
end

return Loader
