# Type to Kill

Roblox experience. Rojo + Wally + Rokit. Strict Luau.

This file is an index, not the rulebook. It exists because it is the only doc
loaded automatically at session start — everything below points at the file
that actually owns each rule. **Read the linked doc before working in its
area**; do not work from this summary alone.

| Topic | Source of truth |
|---|---|
| File layout, the `Init`/`Start` lifecycle, data flow | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Replica vs ByteNet, persistence, remote patterns | [NETWORKING-AND-DATA.md](NETWORKING-AND-DATA.md) |
| UI scaling and motion | [UI-AND-MOTION.md](UI-AND-MOTION.md) |
| Verification you must pass before saying "done" | [.claude/rules/quality-gate.md](.claude/rules/quality-gate.md) |
| Instance naming | [.claude/rules/model-naming-style.md](.claude/rules/model-naming-style.md) |
| Which model may run as a subagent | [.claude/rules/subagent-model-policy.md](.claude/rules/subagent-model-policy.md) |

`default.project.json` is the authoritative disk → Roblox tree map. When it and
a doc disagree, the project file wins.

---

## Before you add anything

**Look first.** This project has an established shape; match it rather than
introducing a parallel one.

- Search for an existing Service, Controller, Module or helper that already
  does the job before writing a new one. Two files agreeing is a convention;
  one is not.
- Keep changes small and local. Don't restructure surrounding code that the
  task didn't ask about.
- If you introduce a genuinely new structural convention, document it in the
  doc that owns that area — an undocumented convention is one nobody else will
  follow.

## Where code goes

| Path | Mounts to | Contains |
|---|---|---|
| `src/server/Main.server.luau` | `ServerScriptService.Main` | The only script in SSS |
| `src/server/Services/` | `ServerStorage.Services` | Lifecycle modules, name ends in `Service` |
| `src/server/Modules/` | `ServerStorage.Modules` | Server helpers, no lifecycle |
| `src/client/Main.client.luau` | `StarterPlayerScripts.Main` | Client bootstrap |
| `src/client/Controllers/` | `StarterPlayerScripts.Controllers` | Lifecycle modules, name ends in `Controller` |
| `src/client/UI/` | `StarterPlayerScripts.UI` | UI helpers, no lifecycle |
| `src/shared/` | `ReplicatedStorage.Shared` | Only what BOTH sides need |
| `src/vendor/` | (vendored upstream) | Byte-identical to upstream. Excluded from lint/format. Don't edit. |

**Rojo overwrites every mounted path on each sync.** Never edit those in
Studio while Rojo is connected — the work is lost silently. Everything else in
the place (GUIs, models, Workspace, Lighting) is authored in Studio and Rojo
never touches it. So: build instances in Studio, find them from code. Don't
construct UI trees in Luau that belong in StarterGui.

## The invariants

- **Enrollment is by name.** A module joins the boot lifecycle only because it
  ends in `Service`/`Controller`. There is no registry to update. Anything else
  is inert and is required directly.
- **`Init()` must not yield.** It is enforced, not advised — the loader errors
  if it does. Register listeners and wire state in `Init`; do loops, waiting
  and network work in `Start()`. Every `Init()` completes before any `Start()`.
- **Require dependencies directly** (`require(script.Parent.DataService)`), so
  types survive. No service locator: one `any` disables typechecking for
  everything downstream of it.
- **State vs events.** If the client would still need the value after a
  rejoin, it is state → Replica. If it is meaningless five seconds later, it
  is an event → ByteNet. Never fire a remote to sync data; that creates a
  second copy of the truth and the two drift.
- **Write player data only through `DataService`.** Mutating `profile.Data`
  directly replicates nothing and silently desyncs the client.
- **The client is never trusted.** It may hold UI state; it may never decide a
  reward, a price, a hit, or an entitlement. Re-validate every packet
  server-side even when the client already checked.
- **Strict Luau.** `--!strict` everywhere. Avoid `any` — if a dependency's
  signature is wrong but the runtime contract is verified, use one narrow,
  commented cast at that call site rather than spreading `any` outward.
- **Prefer an installed package** over reimplementing it. Check `wally.toml`
  first; note that `wally.toml` also records libraries deliberately *rejected*
  and why, so read the comments before adding a dependency.

## Verifying your work

Full gate list and when each applies: [.claude/rules/quality-gate.md](.claude/rules/quality-gate.md).
The commands below are the ones this project actually uses — all three pass on
a clean tree, so a failure is yours:

```powershell
selene src/                                     # 0 errors, 0 warnings
stylua --check src/                             # never reformat as a side effect
rojo build default.project.json -o "$env:TEMP/out.rbxlx"
```

Write build artifacts to the temp dir, never into the repo. This is a Windows
box — don't use `/tmp`.

A green build proves it compiles, not that it works. The Roblox Studio MCP is
configured in `.mcp.json`: use `get_studio_state`, `start_stop_play` and
`get_console_output` to run a Play smoke test and read the boot lines. Restart
Play after a sync — a session started before your change is running old code.

Expected console noise in Studio, not caused by your change: DataStore
`StudioAccessToApisNotAllowed` (API access off), `ConfigService: Config value
not found for key "developers"`, and anything from Studio plugins.

## Setup

```powershell
rokit install    # pinned toolchain — versions live in rokit.toml
wally install    # restores Packages/ and ServerPackages/ (gitignored)
rojo serve       # then: Rojo plugin → Connect, in Studio
```
