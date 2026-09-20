# Architecture

## The map

| Where | What lives there | Studio-safe to edit? |
|---|---|---|
| `src/server/Main.server.luau` | → `ServerScriptService.Main`. The only script in SSS. | **No — Rojo overwrites** |
| `src/server/Services/` | → `ServerStorage.Services`. Server lifecycle modules. | **No — Rojo overwrites** |
| `src/server/Modules/` | → `ServerStorage.Modules`. Server helpers, no lifecycle. | **No — Rojo overwrites** |
| `src/client/Main.client.luau` | → `StarterPlayerScripts.Main` | **No — Rojo overwrites** |
| `src/client/Controllers/` | → `StarterPlayerScripts.Controllers`. All client logic. | **No — Rojo overwrites** |
| `src/client/UI/` | → `StarterPlayerScripts.UI`. UI helpers, no lifecycle. | **No — Rojo overwrites** |
| `src/shared/` | → `ReplicatedStorage.Shared`. Only what both sides need. | **No — Rojo overwrites** |
| `src/vendor/Replica/` | → `ReplicatedStorage.ReplicaShared` + `.ReplicaClient`, `ServerStorage.ReplicaServer` | **No — vendored** |
| `Packages/`, `ServerPackages/` | Wally-installed. Gitignored. | **No — `wally install` regenerates** |
| **Everything else in Studio** | GUIs, models, Workspace, Lighting | **Yes — this is yours** |

Scripts live in VS Code. Instances live in Studio. Rojo mounts only scripts, so it never fights your Lighting or your GUI tree.

**Anything Rojo mounts is overwritten on every sync. Editing those in Studio silently loses your work.**

---

## Adding a new file

### Recipe 1 — a server service

Create `src/server/Services/ShopService.luau`. **The name must end in `Service`.** That suffix is the only thing that enrolls it — there is no registry to update, no bootstrap line to add.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("ShopService")

local ShopService = {}

function ShopService.Init()
	-- Wire state. Register listeners. MUST NOT YIELD.
	-- Nothing else has Start()ed yet -- don't call into other services here.
end

function ShopService.Start()
	-- May yield freely. Loops, network calls, waiting.
	-- Every other module's Init() has finished by now.
	log.info("ready")
end

return ShopService
```

Save. Rojo syncs it. It loads. That's the whole workflow.

### Recipe 2 — a client controller

Identical, but `src/client/Controllers/ShopController.luau`, ending in `Controller`.

### Recipe 3 — a plain module (no lifecycle)

Name it anything that does **not** end in `Service`/`Controller` — e.g. `src/client/UI/Motion.luau`. The loader ignores it entirely. Require it directly from whoever needs it. Use this for pure helpers with no startup behaviour.

### Recipe 4 — a new data field

One line in `TEMPLATE` in `src/server/Services/DataService.luau`:

```lua
local TEMPLATE = {
	Version = DATA_VERSION,
	Coins = 0,
	Gems = 0,   -- <-- that's it
}
```

`profile:Reconcile()` backfills it onto every existing profile automatically. It persists and replicates with no other edit.

If you **reshape** an existing field rather than add a new one, bump `DATA_VERSION` and add a migration — `Reconcile()` only adds missing keys, it cannot rename or restructure.

---

## Using another module

Require it directly, at the top of the file:

```lua
local DataService = require(script.Parent.DataService)
```

Typed. Autocompletes. F12 jumps to it. Rename-refactor works.

This is why there's no Service Locator: `Locator:Get("DataService")` returns `any`, and in strict Luau a single `any` silently disables typechecking for everything downstream — `Locator:Get("DataService"):set(player, "oops")` would typecheck clean.

**If two modules genuinely need each other**, defer one side. The annotation is erased at runtime, so no require cycle exists, but types still resolve:

```lua
local Other: typeof(require(script.Parent.OtherService)) = nil :: any

function MyService.Init()
	Other = require(script.Parent.OtherService)  -- safe: all bodies already ran
end
```

---

## Init vs Start

| | `Init()` | `Start()` |
|---|---|---|
| Yielding | **Forbidden — errors loudly** | Fine |
| Runs | Sequential, `Priority` desc | Spawned, parallel |
| Use for | Registering listeners, wiring state | Loops, network, waiting |
| Can call other services? | No | Yes |

The invariant: **every module body and every `Init()` completes before any `Start()` runs.** That's what lets `Start()` touch anything without ordering anxiety.

The no-yield rule is enforced, not documented — the loader runs `Init` in a coroutine and errors if it isn't dead after one resume. Without that, one stray `WaitForChild` in an `Init` silently reorders your whole boot.

`Priority` (default 0, higher first) orders `Init` only. Reach for it rarely — `DataService` uses `100` so it loads before anything reading player data.

---

## Data: ProfileStore + Replica

**ProfileStore is the disk. Replica is the wire.**

The idea that makes it click:

```lua
Replica.New({ Token = TOKEN, Data = profile.Data })
```

`Data = profile.Data` **does not copy the table** — the replica references the *same* table ProfileStore saves. So one `replica:Set({"Coins"}, 100)` mutates the profile *and* replicates. There is only one copy of the truth.

**Server** — always through `DataService`:
```lua
DataService.set(player, {"Coins"}, 100)
DataService.set(player, {"Settings", "MusicEnabled"}, false)
```

**Client**:
```lua
local DataController = require(script.Parent.DataController)

DataController.observe({"Coins"}, function(coins)
	label.Text = `{coins}`   -- fires now AND on every change
end)
```

### Rules

- **Never touch `profile.Data` directly.** `profile.Data.Coins = 5` mutates but sends nothing — the client silently drifts. Only the setters replicate. That's why `DataService.set` is the only exposed write path.
- **No gaps in numeric tables, no non-string/number keys.** Replica can't replicate them. (Its own docs, verbatim.)
- **`Subscribe` needs a *ready* player** — ready means their client called `RequestData()`. Subscribing early is a silent no-op. `DataService` handles this via `Replica.ReadyPlayers` / `Replica.NewReadyPlayer`.
- **`RequestData()` runs last**, in `Main.client.luau`, after `Loader.load()`. `OnNew` does not replay replicas that already arrived — register in `Init()` or miss them permanently.

### Why not attributes

Attributes are great for scalars and Studio visibility, but every attribute on a `Player` replicates to **every** client — there is no private attribute in any encoding, so a pity counter or anticheat flag is readable by any exploiter in one line. Replica's `Subscribe(player)` sends to one client only, handles nested tables natively, and batches.

---

## Gotchas worth knowing up front

- **`ReplicaShared` must be at `ReplicatedStorage.ReplicaShared`.** Hardcoded in the library (`ReplicaServer.luau:88`). Don't move it.
- **`ProfileStore.Mock` in Studio** — without it, Studio testing with API services on writes to **live player keys**, and a bad migration tested in Studio corrupts real data. `DataService.Init` handles this.
- **`Replica.Token(name)` errors if called twice with the same string.** Keep tokens at module scope, never inside a function.

---

## Commands

```bash
rojo serve                                    # sync to Studio (the normal workflow)
rojo build default.project.json -o test.rbxlx # syntax check / CI
wally install && wally-package-types --sourcemap sourcemap.json Packages/
selene src/
stylua src/
```
