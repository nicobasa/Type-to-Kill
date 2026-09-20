# Networking & Data

Companion to [ARCHITECTURE.md](ARCHITECTURE.md). That doc tells you where files go; this one tells you how to move a value from one machine to the other.

---

## First: which pipe?

You have two, and picking the wrong one is the single most common way this stack goes bad. They are not interchangeable.

| | **Replica** | **ByteNet** |
|---|---|---|
| Moves | **State** — a value that *exists* | **Events** — a thing that *happened* |
| Direction | Server → client only | Both ways |
| Persists? | Yes (it's the same table ProfileStore saves) | No |
| Late joiner gets it? | **Yes, automatically** | No — they missed it |
| Examples | Coins, Level, Inventory, Settings | "you got hit", "play this sound", "I pressed the boost key" |

The rule, and it is a rule:

> **If the client would need the value after a rejoin, it is state — use Replica.**
> **If the value is meaningless five seconds later, it is an event — use ByteNet.**

**Never fire a remote to sync data.** The moment you write `Net.coinsChanged.sendTo({ coins = 50 }, player)` you have created a second copy of the truth, and the two will drift — a client who joins late, or misses one packet, is silently wrong forever with no error to find. `Coins` lives in the template, and `DataController.observe` already fires for late joiners *and* on every change. That path cannot drift, because there is only one table.

The honest test: *"if this packet never arrives, is the client wrong, or just less informed?"* Wrong → Replica. Less informed → ByteNet.

---

# Part 1 — Server fires an event to the client

Worked example: server tells a client to show a toast notification.

## Step 1 — Define the packet (shared, once)

Packets are defined **once, in a shared module both sides require.** Not once per side. The client's `defineNamespace` looks up each packet's numeric ID from data the *server* replicated, so if the two sides define different packet sets, the IDs don't line up and you get silent cross-wiring or a hard error.

Create **`src/shared/Net.luau`**:

```lua
--!strict
--[[
	Packet definitions. ONE namespace, required by both sides.

	This is a plain module -- the name doesn't end in Service/Controller, so the
	Loader ignores it (ARCHITECTURE.md, Recipe 3). Require it directly.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local NAMESPACE = "Game"

-- On the CLIENT this require yields until the server has created
-- ReplicatedStorage.BytenetStorage. That's ByteNet's own WaitForChild.
local ByteNet = require(ReplicatedStorage.Packages.ByteNet)

--[[
	Why this guard exists -- do not delete it.

	ByteNet waits for the BytenetStorage *folder*, but looks up the individual
	namespace with FindFirstChild, NOT WaitForChild
	(Packages/_Index/ffrostflame_bytenet@0.4.6/bytenet/src/replicated/values.luau).
	If our namespace's StringValue hasn't replicated yet, access() returns nil and
	defineNamespace immediately indexes it -> "attempt to index nil with 'read'".

	The folder existing does NOT imply our namespace inside it exists. That gap is
	the whole bug, and it only opens on a cold boot (Studio Play, or the first
	player into a fresh server), which is exactly when you'd blame something else.
]]
if RunService:IsClient() then
	local storage = ReplicatedStorage:WaitForChild("BytenetStorage")
	if storage:WaitForChild(NAMESPACE, 10) == nil then
		error(
			`[Net] namespace "{NAMESPACE}" never replicated.\n`
				.. "The server never required Shared.Net, so it never published the packet IDs.\n"
				.. "Fix: require it from any *Service (a require at file scope is enough).",
			0
		)
	end
end

return ByteNet.defineNamespace(NAMESPACE, function()
	return {
		-- server -> client
		notify = ByteNet.definePacket({
			value = ByteNet.struct({
				message = ByteNet.string,
				duration = ByteNet.float32,
			}),
		}),

		-- client -> server (see Part 3)
		requestBoost = ByteNet.definePacket({
			value = ByteNet.nothing,
		}),
	}
end)
```

**The server must require this module or the client hangs for 10s and then errors.** The namespace's StringValue is only created when `defineNamespace` runs *server-side*. A packet that only the client ever touches will never work. Requiring `Net` at the top of any `*Service` is enough.

## Step 2 — Fire it from the server

```lua
-- src/server/Services/NotifyService.luau
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)

local NotifyService = {}

function NotifyService.tell(player: Player, message: string, duration: number?)
	Net.notify.sendTo({
		message = message,
		duration = duration or 3,
	}, player)
end

return NotifyService
```

**The player is the *second* argument, not the first.** This is deliberate in ByteNet's design and it will bite you at least once. Four send methods exist:

| Call | Sends to |
|---|---|
| `sendTo(data, player)` | one player |
| `sendToList(data, { p1, p2 })` | several |
| `sendToAll(data)` | everyone |
| `sendToAllExcept(data, player)` | everyone but one |

## Step 3 — Listen on the client

**Register the listener in `Init()`, never `Start()`.** Same reason `DataController` does — see the comment in [DataController.luau:26-35](src/client/Controllers/DataController.luau#L26-L35). `Init()` is guaranteed to have finished for *every* module before *any* `Start()` runs, so a listener registered in `Init` cannot miss a packet that a fast `Start` elsewhere provoked.

```lua
-- src/client/Controllers/NotifyController.luau
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("NotifyController")

local NotifyController = {}

function NotifyController.Init()
	Net.notify.listen(function(data)
		-- data.message, data.duration -- typed, no casting
		log.info(`notify: {data.message} ({data.duration}s)`)
	end)
end

return NotifyController
```

That's the whole loop. Save, Rojo syncs, both modules load themselves — no registry, no bootstrap line.

## Step 4 — Check it

Play, then in the **server** command bar:

```lua
require(game.ServerStorage.Services.NotifyService).tell(game.Players:GetPlayers()[1], "hello", 5)
```

You should see `[C][NotifyController] notify: hello (5s)` in the client output.

---

# Part 2 — Adding data that persists

## Step 1 — Add the field to the template

One line in `TEMPLATE` in [DataService.luau:43-52](src/server/Services/DataService.luau#L43-L52):

```lua
local TEMPLATE = {
	Version = DATA_VERSION,
	Coins = 0,
	Level = 1,
	Gems = 0,              -- <-- new. That's the entire change.
	Inventory = {} :: { [string]: number },
	Settings = {
		MusicEnabled = true,
	},
}
```

`profile:Reconcile()` backfills it onto every existing profile on load. It persists, it replicates, and it's typed — `PlayerData` is `typeof(TEMPLATE)`, so `Gems` autocompletes everywhere immediately. **No other edit anywhere.**

Two constraints Replica imposes on what you can put here:

- **No gaps in numeric arrays**, and **no keys that aren't strings or numbers.** Those can't be replicated.
- Nested tables are fine and expected — that's the point of Replica.

## Step 2 — Adding vs. reshaping (this is the one that hurts)

`Reconcile()` **only adds missing keys.** It cannot rename, split, merge, or retype anything.

- **Adding `Gems = 0`?** Just do it. No version bump.
- **Changing `Coins` from a number to `{ amount = 0, lifetime = 0 }`?** Bump `DATA_VERSION` and write a migration.

```lua
local DATA_VERSION = 2   -- was 1

-- Index N migrates version N -> N+1. Never delete or renumber one.
local MIGRATIONS: { (data: any) -> () } = {
	[1] = function(data)
		data.Coins = { amount = data.Coins or 0, lifetime = data.Coins or 0 }
	end,
}
```

`runMigrations` walks every version from the profile's stored one up to current, so a player who last logged in three shapes ago is carried through each step in order.

Why `Version` is in the template from day one, before you need it: without a version already saved in every profile, you **cannot distinguish** "old shape" from "new shape that happens to hold defaults." At that point your only options are a data wipe or a permanent guess-the-shape hack. It costs one integer.

## Step 3 — Writing it (server only)

**Every mutation goes through a `DataService` setter. Never touch `profile.Data` directly.**

```lua
local DataService = require(script.Parent.DataService)

DataService.set(player, { "Gems" }, 50)
DataService.set(player, { "Settings", "MusicEnabled" }, false)

-- Batch siblings under one path into a single packet:
DataService.setValues(player, { "Settings" }, { MusicEnabled = false, SfxEnabled = true })
```

A raw `profile.Data.Gems = 50` mutates the table and **sends nothing.** No error, no warning — the client just silently drifts and you find out from a bug report. The setters are the only things that both mutate *and* replicate, which is exactly why `set` is the only exposed write path.

Increments read-then-write through the setter:

```lua
local data = DataService.getData(player)
if data then
	DataService.set(player, { "Gems" }, data.Gems + 5)
end
```

## Step 4 — Reading it on the server

```lua
local data = DataService.getData(player)   -- PlayerData?, nil if not loaded yet
if data == nil then
	return   -- player left, or joined microseconds ago
end
print(data.Gems)
```

It's `nil`-able for a real reason: `getData` returns nil between the player joining and their profile session starting. Handle it rather than asserting it away.

---

# Part 3 — Getting it on the client

## The normal way: `observe`

99% of the time this is all you want:

```lua
-- src/client/Controllers/HudController.luau
--!strict
local DataController = require(script.Parent.DataController)

local HudController = {}

function HudController.Start()
	DataController.observe({ "Gems" }, function(gems)
		gemsLabel.Text = `{gems}`
	end)
end

return HudController
```

`observe` fires **immediately with the current value, and again on every change.** That "and immediately" is what kills the classic bug where the HUD shows the Studio placeholder text for the first half-second. It waits for the data internally, so it's safe to call from `Start()`.

### `observe` sees every kind of write

You do not have to care which setter the server used. All of these fire an observer on `{"Settings","MusicEnabled"}`:

```lua
DataService.set(player, { "Settings", "MusicEnabled" }, false)
DataService.setValues(player, { "Settings" }, { MusicEnabled = false })
```

And observing a **container** fires for writes *inside* it, which is what you want for inventories:

```lua
DataController.observe({ "Inventory" }, function(inv)
	-- fires for set(plr, {"Inventory","Sword"}, 1) too
end)
```

This is worth stating explicitly because it is *not* free, and an earlier cut of this codebase got it wrong. Replica's `OnSet` is keyed on an exact path string and is fired **only** by `Set` — `SetValues`, `TableInsert` and `TableRemove` fire `OnChange` and nothing else ([ReplicaClient.luau:393-421](src/vendor/Replica/ReplicaClient.luau#L393-L421)). An `OnSet`-based observer is silently blind to three of the four write actions *and* to nested writes. `observe` is built on `OnChange` and re-reads the path, so it can't drift out of sync with the server's choice of setter. Don't "optimise" it back onto `OnSet`.

## One-shot reads

```lua
if DataController.await(10) then          -- yields; false on timeout
	local data = DataController.getData() -- nil until await() succeeds
	print(data.Gems)
end
```

`await` is per-player readiness — "*my* data is here" — deliberately not a global "server booted" flag. A player joining a 40-minute-old server would sail straight past a global flag that flipped ages ago and read an empty table. That gap is exactly where "coins show 0 for half a second" lives.

## Client → server ("grabbing it" the other way)

The client **cannot** write data. It asks, and the server decides. This is not ceremony — a client-authoritative write is an exploit, full stop.

```lua
-- client
Net.requestBoost.send()
```

```lua
-- server, in a *Service Init()
Net.requestBoost.listen(function(_data, player)
	-- `player` is injected by ByteNet and is NOT spoofable. Trust it.
	-- Everything in `_data` came from the client. Trust none of it.
	local data = DataService.getData(player)
	if data == nil or data.Gems < 10 then
		return   -- validate server-side. Always.
	end
	DataService.set(player, { "Gems" }, data.Gems - 10)
end)
```

ByteNet validates the packet's *shape* for you, so a malformed packet never reaches your callback. It cannot validate *meaning* — "do they have enough gems", "are they close enough", "is this on cooldown" is on you, on the server, every time.

---

## Gotchas, collected

| Symptom | Cause |
|---|---|
| `attempt to index nil with 'read'` on client boot | Namespace StringValue hadn't replicated. Keep the `WaitForChild` guard in `Net.luau`. |
| Client hangs 10s then `namespace never replicated` | No server-side module requires `Shared.Net`, so the IDs were never published. |
| `observe` never fires | Path typo, or the field isn't in `TEMPLATE`. The setter used does *not* matter — see above. |
| Client's value silently stale | Something wrote `profile.Data.X = y` directly instead of `DataService.set`. |
| `Init() yielded` error at boot | A `WaitForChild`/`await` in `Init`. Move it to `Start`. |
| Packet listener misses early packets | Registered in `Start()`. Register in `Init()`. |
| `Replica.Token` errors on second call | Token created inside a function. Keep tokens at module scope. |
| Data missing on rejoin | You fired an event instead of writing state. Re-read the table at the top. |

---

## Cheat sheet

```
STATE (persists, late joiners get it)          EVENT (transient)
──────────────────────────────────────         ──────────────────────────────────
Add:    TEMPLATE in DataService                Define: src/shared/Net.luau
Write:  DataService.set(plr, {"Gems"}, 50)     Server: Net.foo.sendTo(data, plr)
Read S: DataService.getData(plr)               Client: Net.foo.send(data)
Read C: DataController.observe({"Gems"}, fn)   Both:   Net.foo.listen(fn)   <- in Init()
```
