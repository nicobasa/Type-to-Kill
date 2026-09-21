# Type to Kill

A Roblox experience built with [Rojo](https://rojo.space/) — scripts live in VS Code, instances live in Studio.

## Setup

Toolchain is pinned in `rokit.toml` and dependencies in `wally.toml`. From the project root:

```powershell
rokit install    # installs rojo, wally, selene, stylua, luau-lsp, wally-package-types at pinned versions
wally install    # restores Packages/ and ServerPackages/ (both gitignored)

# Roblox API types for luau-lsp. Gitignored and fetched rather than committed,
# because they go stale as Roblox ships API changes.
curl -fsSL -o globalTypes.d.luau https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau
```

## Daily workflow

```powershell
rojo serve
```

Then in Roblox Studio: **Rojo plugin → Connect**. Every save in VS Code syncs to the place.

## Where things go

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full map. The short version:

| Path | Mounts to |
|---|---|
| `src/server/Main.server.luau` | `ServerScriptService.Main` — the only script in SSS |
| `src/server/Services/` | `ServerStorage.Services` — lifecycle modules (`*Service`) |
| `src/server/Modules/` | `ServerStorage.Modules` — helpers, no lifecycle |
| `src/client/Main.client.luau` | `StarterPlayerScripts.Main` |
| `src/client/Controllers/` | `StarterPlayerScripts.Controllers` — lifecycle modules (`*Controller`) |
| `src/client/UI/` | `StarterPlayerScripts.UI` — helpers, no lifecycle |
| `src/shared/` | `ReplicatedStorage.Shared` |
| `src/vendor/Replica/` | `ReplicatedStorage.ReplicaShared` + `.ReplicaClient`, `ServerStorage.ReplicaServer` |

**Rojo overwrites everything it mounts on every sync.** Editing those paths inside Studio silently loses your work. Everything else in the place — GUIs, models, Workspace, Lighting — is yours to edit in Studio; Rojo never touches it.

A module is enrolled in the boot lifecycle purely by its name ending in `Service` or `Controller`. There is no registry to update.

## Checks

```powershell
selene src/                                        # lint
stylua --check src/                                # format check
rojo build default.project.json -o build.rbxlx     # compile check -- syntax only

# Type check. The three above do not look at types at all: `local x: number = "a"`
# compiles clean and fails at runtime. This is the gate that catches that.
rojo sourcemap default.project.json -o sourcemap.json
luau-lsp analyze --definitions=globalTypes.d.luau --sourcemap=sourcemap.json `
  --base-luaurc=.luaurc --ignore="src/vendor/**" src/
```

Regenerate the sourcemap before analyzing whenever files were added, moved or
renamed — `luau-lsp` resolves `script.Parent.X` through it, so a stale sourcemap
reports errors about files that are fine.

## Docs

- [CLAUDE.md](CLAUDE.md) — start here: the index of every rule, and what Claude loads automatically
- [ARCHITECTURE.md](ARCHITECTURE.md) — file layout, the `Init`/`Start` lifecycle, data flow
- [NETWORKING-AND-DATA.md](NETWORKING-AND-DATA.md) — Replica vs ByteNet, persistence, remote patterns
- [GAMEPLAY.md](GAMEPLAY.md) — the match loop, the four-digit code, maps, modes, items, rewards
- [UI-AND-MOTION.md](UI-AND-MOTION.md) — UI scaling and motion conventions
- `.claude/` — rules, skills, agents and commands that let Claude work in this repo without being re-briefed
