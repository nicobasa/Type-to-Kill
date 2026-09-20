# Quality Gate: self-review & verification

Pass these gates before declaring work complete. **A gate you did not run is not a gate that passed** — say so explicitly rather than implying it was clean.

---

## Gate 1: Derive the gates before running them

Do not assume the commands. Read the repo's own config and run what actually exists:

| Read this | To learn |
|---|---|
| `rokit.toml` (or `aftman.toml` / `foreman.toml`) | the real toolchain + pinned versions — quote these, never recall them |
| `default.project.json` | the project file to build, and what's mounted where |
| `selene.toml` | lint config, `exclude` globs, rule overrides |
| `stylua.toml` | format config |
| `.luaurc` | enabled lints, and whether `lintErrors` makes them fatal |

Typical suite once derived:

```bash
selene src/                    # if selene.toml exists
stylua --check src/            # --check only; never reformat as a side effect
rojo build <project>.project.json -o <scratchpad>/out.rbxlx
```

If the file/folder structure changed, regenerate the sourcemap **before** type analysis:

```bash
rojo sourcemap <project>.project.json -o sourcemap.json
luau-lsp analyze --sourcemap=sourcemap.json src/
```

Rules:
- **Write build artifacts to the scratchpad/temp dir, never into the repo.** This is a Windows box — do not use `/tmp`.
- Match the real project filename and extension; don't guess `.rbxl` vs `.rbxlx`.
- If a tool isn't on PATH (`luau-lsp` often isn't — it's usually editor-provided), **say so** and lean on runtime verification. Never skip a gate silently.
- Don't call a warning "noise" without pointing at the config that makes it so.

---

## Gate 2: Luau self-review checklist

Re-read every `.luau` file you changed and check each item. These are real parser/semantic traps, not style.

- [ ] **No type annotation on a table-property assignment** — Luau doesn't allow it.
  ```lua
  -- NG: not valid Luau
  Module.ITEMS: { string } = { "A", "B" }

  -- OK: cast
  Module.ITEMS = { "A", "B" } :: { string }

  -- OK: omit when obvious
  Module.ITEMS = { "A", "B" }
  ```

- [ ] **No method chain directly off a call result** — split to a temp local.
  ```lua
  -- NG
  Remotes.SomeEvent():OnClientEvent:Connect(handler)

  -- OK
  local remote = Remotes.SomeEvent()
  remote.OnClientEvent:Connect(handler)
  ```

- [ ] **`InvokeServer()` is pcall-wrapped** — a RemoteFunction call can throw.
  ```lua
  local ok, result = pcall(function()
      return remote:InvokeServer(args)
  end)
  if not ok then return end
  ```

- [ ] **`export type` is at module top level**, never inside a function.

- [ ] **String interpolation uses `{}`, not `${}`.**
  ```lua
  Text = `Lv.{level}`   -- OK
  Text = `Lv.${level}`  -- NG
  ```

- [ ] **Locks/overrides are released on every path, including errors.** Luau has no `finally` — use `pcall` and release explicitly afterwards, or a cleanup object that owns the release:
  ```lua
  acquire()
  local ok, err = pcall(work)
  release()             -- runs whether work threw or not
  if not ok then error(err, 0) end
  ```

- [ ] **Connections and instances are cleaned up.** `Instance:Destroy()` disconnects that instance's own event connections; the real leaks are `Parent = nil` instead of `Destroy`, per-player tables never cleared on leave, and closures holding upvalues.

- [ ] **Read-modify-write on persisted data is not split across a yield.** Two concurrent handlers that each read, add, and write will lose one of the writes. Use whatever atomic/locked write path this project actually provides — read the persistence layer to find out what that is.

---

### Strict typing and dependency boundaries

- Design strict-typed locals before implementation. Values from different API variants, such as live and mock stores, may expose structurally different types; use separate locals or an explicit shared interface instead of late reassignment.
- Read the actual vendored/package signature before calling constructors, factories, metatable APIs, or generics. Confirm parameter and return types at the boundary.
- If a dependency signature is inaccurate but the runtime contract is verified, use one narrow, documented compatibility cast at that call site. Never spread `any` through the module or disable strict checking.
- Treat every `--!strict` diagnostic as a defect to resolve before handoff, even when the code would run correctly.

## Gate 3: Runtime verification via the Roblox Studio MCP

If Studio is running, verify behavior — a green build proves compilation, not that it works.

The tool is **`mcp__Roblox_Studio__execute_luau`** (confirm the server name in `.mcp.json`). Companions: `get_studio_state`, `get_console_output`, `start_stop_play`.

**Caveats that will produce false results if ignored:**

- **`execute_luau` is stateless between calls** — re-acquire every instance ref in each call.
- **It runs in a separate Luau VM with its own `require` cache.** `require()`-ing a live game module through it returns a **fresh instance whose lifecycle hooks never ran** — empty state, no listeners. You cannot inspect live module state this way. Read the **console** instead, or have the game's own code report.
- **Check the mode first** (`get_studio_state`) — `Edit` is unavailable during Play and vice versa.
- **A Play session started before your change synced is running the old code.** Restart Play before concluding anything.
- **Never edit scripts in Studio while Rojo is connected** — Rojo overwrites mounted paths.

Useful checks: confirm a new instance/module exists in the tree; run a Play smoke test and read `get_console_output` for red errors and the project's own boot lines.

---

## Gate 4: Change-impact check

- **Find every caller.** Grep for the name of anything whose signature, shape, or behavior you changed — all of them, not the ones you remember.
- **Check init/boot order.** If you added or reordered a module, confirm the load order still satisfies its dependencies. Read the actual entry-point scripts; don't assume their names or casing.
- **Check the mirror side.** A change to a shared contract (a packet shape, a data schema, a type) usually needs the other side updated in the same commit.

---

## When each gate applies

| Scenario | Required gates |
|---|---|
| New `.luau` file | 1 + 2 + 3 + 4 |
| Edit existing `.luau` | 1 + 2 + 4 |
| Change a shared contract (packets, schema, types) | 1 + 2 + 3 + 4 |
| UI change | 1 + 2 + 3 |
| Declaring all work complete | 1 + 2 + 3 + 4 |

---

## Common Luau traps (from real bugs)

1. **Type annotation on a table property** → use a `:: Type` cast, or omit.
2. **Method chain off a call result** → split into a temp local.
3. **Mixed types in one field** (`boolean` and `string`) → pick one and stay consistent.
4. **Unhandled `InvokeServer` error** → always `pcall`.
5. **Non-atomic read-modify-write on saved data** → use the project's locked/atomic write path.
6. **Lock never released on the error path** → `pcall` + explicit release (no `finally` in Luau).
7. **Cleanup missed on character/player removal** → disconnect and clear per-player state.
8. **NaN defeats a range check** → `n < 0 or n > MAX` passes for `0/0`. Add an explicit `n ~= n` check.
9. **`#` on a table with embedded nils is undefined** → use `select("#", ...)` for client-arg arity.
