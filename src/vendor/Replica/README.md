# Replica (vendored)

State replication with lifecycle handling and per-client subscription control,
by MAD STUDIO (loleris). Upstream: https://github.com/MadStudioRoblox/Replica

## Why this is vendored instead of a Wally dependency

There is no first-party Wally package for Replica — every entry in the
registry is a third-party fork or snapshot, none of them published by the
author. Depending on one would mean trusting a stranger's copy of the
persistence-adjacent layer and inheriting whatever they changed. So the
upstream source is committed here instead. `wally.toml` records the same
reasoning next to the `ProfileStore` dependency.

## Rules

**Keep these files byte-identical to upstream.** That is the whole point: the
next update is then a clean diff instead of an archaeology exercise. Both tool
configs already exclude this directory so nothing rewrites it behind your back:

- `selene.toml` → `exclude = ["src/vendor/**"]`
- `.styluaignore` → `src/vendor/`

Do not reformat, do not "fix" lint warnings, do not restyle. If you need
different behaviour, wrap it from `src/server/` or `src/client/` rather than
editing here — a local edit is invisible at update time and will be silently
reverted by whoever updates next.

## Layout, and one constraint that is not negotiable

`default.project.json` mounts these as:

| File | Mounts to |
|---|---|
| `ReplicaShared/` | `ReplicatedStorage.ReplicaShared` |
| `ReplicaClient.luau` | `ReplicatedStorage.ReplicaClient` |
| `ReplicaServer.luau` | `ServerStorage.ReplicaServer` |

**`ReplicaShared` must stay at exactly `ReplicatedStorage.ReplicaShared`** —
the path is hardcoded inside `ReplicaServer.luau`. Moving or renaming that
mount breaks the library at runtime, not at build time.

## Updating

1. Copy the new upstream files over these, unchanged.
2. Re-check that mount table above against the new file names.
3. Re-read upstream's changelog for anything touching `Replica.New`,
   `Subscribe`, or the ready-player signals — `src/server/Services/DataService.luau`
   depends on all three.
4. Run a Play smoke test and confirm `[ReplicaClient]: Initial data received`
   still appears in the console.

See [ARCHITECTURE.md](../../../ARCHITECTURE.md) for how Replica pairs with
ProfileStore, and [NETWORKING-AND-DATA.md](../../../NETWORKING-AND-DATA.md)
for when to use it instead of ByteNet.
