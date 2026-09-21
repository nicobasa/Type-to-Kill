# Gameplay

Companion to [ARCHITECTURE.md](ARCHITECTURE.md) (where files go) and
[NETWORKING-AND-DATA.md](NETWORKING-AND-DATA.md) (how values move). This one covers the
game itself: the match loop, the four-digit code, and how to add a map, a mode or an item
without touching anything else.

---

## The one-paragraph version

Every living player wears a four-digit number on their head. You kill someone by reading
their number and typing it. The server owns every code, decides every kill, and is the
only thing that can grant Cash or XP. Rounds are ten minutes of Team Deathmatch or Free
For All on one of six maps, picked by vote.

---

## The match loop

One state machine, in `RoundService`. It is the only writer of the round replica and the
only thing that moves the match forward.

```
Lobby  ──►  Voting  ──►  MapLoading  ──►  WaitingToPlay  ──►  RoundActive  ──►  RoundResults
  ▲          (15s)        (loads the         (5s, PLAY          (10min, or          (5s)
  │                        winner)            is enabled)        until a goal)        │
  └────────────────────────────────────────────────────────────────────────────────────┘
```

The legal moves live in a table in [`src/shared/Match.luau`](src/shared/Match.luau), not in
`if` statements, so an illegal transition is refused at the call site instead of quietly
reordering the match. Every state also has an escape back to `Lobby` for "the last player
left".

**`TeamSelect` is deliberately not one of these states.** A player who joins eight minutes
into a live Team Deathmatch still has to pick a side, and the match is not going to leave
`RoundActive` to let them. Team selection is a *per-player* phase (`Match.PlayerPhase`:
`Menu` → `TeamSelect` → `Playing` → `Killcam`) that runs against whatever global state is
current.

### Nothing is reset by name

`RoundService` does not know that `ScoreService`, `CodeService`, `SpawnService` or
`LoadoutService` exist. Each of them subscribes to `RoundService.onStateChanged` in its own
`Init()` and reacts to the phase it cares about:

| Service | Reacts to | Does |
|---|---|---|
| `ScoreService` | → `WaitingToPlay` | clears scores |
| `LoadoutService` | → `WaitingToPlay` | clears loadouts, spawns the new map's pickups |
| `CodeService` | leaving `RoundActive` | releases every code |
| `SpawnService` | leaving `RoundActive` | cancels pending respawns and protection timers |
| `GrenadeService` | leaving `RoundActive` | destroys live grenades and clouds |
| `RewardService` | → `RoundResults` | grants match rewards, exactly once |
| `ParticipantService` | → `Lobby` | everyone back to `Menu` |

That is the whole reason `onStateChanged` exists. A loop that reached into eight services
by name is a loop nobody can add a ninth service to — and most of those services already
read `RoundService.getState()`, so every one of those edges would be a require cycle.

### Time is absolute, never a countdown

`Round.PhaseEndsAt` is an absolute `workspace:GetServerTimeNow()`. Clients subtract their
own `GetServerTimeNow()`, which Roblox keeps synchronised. A replicated *remaining seconds*
field would need a packet per second and would still drift. Nothing in this codebase
replicates a countdown.

---

## The round replica

The profile replica (`DataService`) is **private, per player**. The round replica
(`RoundService`) is the mirror image: **one replica, `:Replicate()`d to everyone**, holding
what every client must agree on.

```
State · ModeId · MapId · PhaseEndsAt
Scores { Red, Blue }
Vote   { MapChoices, MapVotes, ModeVotes }
Players[Match.playerKey(userId)] = { DisplayName, Level, Team, Phase, Kills, Deaths, Alive, LastKillAt }
```

`Match.playerKey(userId)` returns `"U12345"`, not `"12345"`. The prefix is load-bearing:
Replica forbids gaps in numeric tables, and a bare numeric-looking key is one `tonumber()`
in a path helper away from turning the dictionary into a sparse array that cannot
replicate. Same reasoning as `Validate.itemId`.

**Public means public.** Everything in this table reaches every client, so nothing secret
may be added to it.

Read it on the client through `MatchController`, never directly — it is the exact twin of
`DataController`, with `observe`, `await` and `getState`.

---

## The four-digit code

`CodeService` owns a pool. On every spawn a player is drawn a **new** code, zero-padded, a
string, unique among living players. On death, respawn, leave or round end it goes back.

A new code per life is not a detail: a permanent code could be memorised once and used to
re-kill the same player the instant they respawn, forever.

**Codes are strings everywhere.** `"0047"` and `47` are the same number and different
codes, and the leading zeros are the whole reason a player can read one off a headband at
a glance. Nothing may put a code through `tonumber()`.

### A code you can see cannot be hidden from you — so hide the ones you can't

The four digits have to be legible on screen for a human to type them, so they have to
reach that client, so a modified client can read them. **There is no version of this
design where a visible code is secret.** Visibility is the mechanic.

What *is* worth doing is making sure a client is only ever **given** the codes it could
already read. The code lives in one server-side table and reaches clients through
`Net.codeVisibility` — per client, and only for players within
`Config.Code.VisibleRange` (110 studs), recomputed every
`Config.Code.VisibilityInterval`.

It is deliberately **not** in the round replica, and deliberately **not** an attribute on
the character. It was an attribute once, and that was a real hole: an attribute
replicates to every client, so every client held every code in the server and one loop
killed the whole lobby. Now a dumper holds only what was already on their screen.

So the layers are:

- **Range** bounds bulk collection. Set it above the distance at which four digits are
  legible, so it never costs a legitimate kill — lower it and you start refusing kills a
  player could honestly have made.
- **Line of sight** hides a code behind a wall (`CodeService.sweepVisibility`). A code
  counts as seen if any of three rays, from the viewer's head to the centre and both ends
  of the Sign, gets through. Bodies never block, and neither does a part you can see
  through (Transparency ≥ 0.5, or Glass). A code that was seen stays visible for
  `Config.Code.SightGrace` (0.4 s) after the rays break, so a post crossing the line does
  not blink it out. It used to be one ray between two fixed heights, and anything that
  crossed it hid a number the player was looking straight at.
- **The server resolves code → player itself.** The client never names a target.
- **Every kill re-validates** state, liveness, team, self and spawn protection.
- **`Config.RateLimit.CodeSubmit`** bounds how fast codes can be tried at all.

Do not add a "make the visible code secret" layer — it cannot work. Add range, checks in
`KillService`, or rate limiting.

### Where the number is drawn

`ServerStorage.Assets.Headband` is an `Accessory`: a `Handle` (the band, sits across the
crown) and a `Sign` (the plate above and in front of the head). `CodeService` attaches it
with `Humanoid:AddAccessory`.

Two things there are load-bearing and were both found by playtest, not by reading:

- **The Sign is held aside across `AddAccessory`.** The engine's accessory fitting rebuilds
  the accessory around its `Handle` and discards every other `BasePart` — the Sign simply
  vanished. It is unparented before the call and welded back after.
- **The Sign is held by a `Weld`, never a `WeldConstraint`.** A `WeldConstraint` captures
  whatever relative CFrame exists when it activates, which inside an accessory is *after*
  the Handle has already moved to the head — that put the Sign 153 studs away. A `Weld`
  carries the offset as data (`C0`), so activation order cannot move it.

The number itself is drawn **client-side**, as a `SurfaceGui` on the Sign's front face
(`CodeDisplayController`). The server ships no label holding a live code. There is no face
on the back of the plate, on purpose: turning away from someone so they cannot read your
code is part of the game. A `BillboardGui` above the head is used only when a character has
no Sign.

A surface gui's text orientation comes from the part's own axes, so which way up the
digits land depends on how the Sign is rotated inside the model. `SIGN_TEXT_ROTATION` is
the one knob for that. It is `0` for the current model, which was checked by capture
(the previous `180` was an untested guess and put the code upside down). Rotate the Sign in
Studio and you must re-check it the same way.

### The kill ladder

`KillService` walks this in order, and the rate limiter runs **first**, before any other
work or logging — answering a flooded packet with an error packet just builds an
amplifier.

`RoundActive` → killer is `Playing` → killer alive → `Validate.code` shape → a living owner
exists → not yourself → target is playing → not a teammate (TDM) → not spawn-protected.

The target's name is only ever sent back on a hit.

---

## Maps

Six maps, listed in [`src/shared/MapCatalog.luau`](src/shared/MapCatalog.luau) by stable
`Id`. The catalog knows names and taglines. **It does not know what is in a map.**

Geometry lives in Studio, under `ServerStorage.Maps.<Id>`, and everything inside is found
**by CollectionService tag**, never by name or coordinate — because a coordinate in a Luau
file is a coordinate nobody can drag in the viewport.

| Tag | On | Carries |
|---|---|---|
| `SpawnPointRed` / `SpawnPointBlue` / `SpawnPointFFA` | a `BasePart` | its CFrame is the spawn pose — position **and** facing |
| `PickupNode` | a `BasePart` | attribute `ItemId`: `"Flashbang"` or `"SmokeGrenade"` |
| `MenuCameraPoint` | a `BasePart` | attribute `Order` (optional); one stop on the menu camera rail |

Names are in [`src/shared/Tags.luau`](src/shared/Tags.luau) so the code side cannot
misspell one.

`MapService.load(id)` clones the model to `Workspace.ActiveMap`; `unload()` destroys it.
Exactly one map is ever in Workspace.

> **The trap, if you write anything that reads these tags:**
> `CollectionService:GetTagged` returns every tagged instance **in the whole game**,
> including the six copies still sitting in `ServerStorage`. Always filter with
> `:IsDescendantOf(activeMap)`. This is the single easiest bug to ship here.

### Adding a seventh map

1. Build it in Studio under `ServerStorage.Maps.YourMapId`.
2. Tag its spawns, pickup nodes and camera points.
3. Add one row to `MapCatalog.LIST`.

That is the whole change. Voting, loading and spawning pick it up with no other edit.

---

## Modes, teams and balance

Modes are in `Match.MODES`. `UsesTeams` is what forks the entire game — team select,
friendly-fire rejection, which score HUD is drawn, how placement is computed. Read that
field; never compare an id to a literal at a call site.

`TeamService` keeps the authoritative counts in its own table, **not** in
`Team:GetPlayers()`, and re-runs the balance check *inside* `assign()`. That re-check is
the entire point: two players hitting the same button in the same frame must not both pass
a check that was true before either of them joined. `Config.Teams.MaxImbalance` (2) is the
most the sides may differ; the larger side locks at that difference.

The client greys out a locked side, but that is presentation. The server decides, and a
rejection comes back as `Net.notice`.

### Adding a mode

Add it to `Match.MODES` and `Match.MODE_ORDER`, add its win condition to `ScoreService`
and its rewards to `Config.Rewards`. The vote UI is already built for three columns.

---

## Items

Two throwables, in [`src/shared/Items.luau`](src/shared/Items.luau). Two toolbar slots,
`Config.Toolbar.SlotCount`.

The slots array is **always** `SlotCount` long, with `""` for empty — never a table with
holes, because `#` on one of those is undefined in Luau.

Grenades are created, owned and simulated **by the server** (`:SetNetworkOwner(nil)`), so
the thrower cannot teleport one. The client contributes exactly one thing the server cannot
compute: the camera's look direction. Neither grenade deals damage.

**Flashbang.** The server checks range and raycasts line of sight, then tells the clients
that passed. The *view cone* test is the client's, because the server knows where a
character faces, not where its camera looks. That split is honest rather than lax: no
server can force a client to render white pixels, so the cone test gains an exploiter
nothing that ignoring the packet outright would not. Everything enforceable — who is close
enough, who is behind a wall — is enforced.

**Smoke.** A server-created cloud instance, so every player's vision is blocked by the same
cloud in the same place. A client-rendered cloud would let one player see through smoke
another player is blind in.

**Dark Flash Effect** (`Settings.DarkFlashEffect`, default off) swaps the flash from white
to black with identical timing. It is an accessibility option for photosensitivity, not a
weaker mode, and it persists with the profile — a preference that has to be re-set every
session fails exactly the people it exists for.

---

## Stamina and sprint

Stated as **durations**, in `Config.Stamina`, because the design is stated in durations:

- full → empty in exactly `DrainDuration` (4s) of real sprinting,
- on release, the bar **holds** at its value for `RegenDelay` (1s) — neither up nor down,
- then refills at an `Max / FullRegenDuration` (3s empty→full) rate,
- sprint cannot re-engage below `ResumeThreshold` after hitting zero.

Rates are derived from those durations on both sides; nothing hardcodes a rate.

**The server sets `Humanoid.WalkSpeed`. The client never does.** The client sends an
*intent* (`Net.setSprinting{active}`), the server checks the stamina it tracks itself, and
sends a correction (`Net.sprintState`) only when its answer differs from what the client
would have drawn. The client predicts the bar locally so it is smooth, and snaps to the
authoritative value on every correction.

The low-stamina warning is a red **overlay that pulses**, not a recolour — the bar keeps
its cyan identity so "low" reads as an alarm on the bar rather than as a different bar. It
is a moderate pulse and must stay one; a fast strobe is a photosensitivity hazard in a game
that already ships a flashbang.

---

## Camera and mouse

The gameplay view is **arms-only first person** (`CameraController`). Two rules keep it
from fighting everything else:

**Shift lock is off**, set per player on the server (`ParticipantService`) — `Player.
DevEnableMouseLock` is not writable from a LocalScript, and attempting it there throws,
which the Loader treats as fatal and takes the whole client down with it. It is off
because Left Shift is the sprint key: with shift lock available every sprint would also
toggle the mouse into locked-centre third person, flipping the camera mode in combat on
the one key a player holds most often.

**Menus hold a camera override.** First person locks the cursor to the centre of the
screen, so any screen the player has to click needs `CameraController.override()` held
for as long as it is up. `MenuCameraController` does this for every screen in
`MENU_SCREENS` — currently `MainMenu` *and* `TeamSelect`. Leaving TeamSelect out of that
list was a real bug: the menu closed, the override came back, and the player was left
looking at a team-select panel they could not move the mouse to click.

If you add another screen the player interacts with while out of the world, add it to
that list. The override is reference counted, and the sync is deferred by a frame because
`UIController` closes the outgoing screen before it opens the incoming one.

## Cash and XP

Persisted in the profile (`Cash`, `Level`, `Experience`). Granted **only** by
`RewardService`, and only through `CashService.add` / `LevelService.addExperience`, which
bound every amount again.

`RewardService.awardKill` returns what was *actually* granted, not the nominal figure —
those setters return a boolean, and a refused grant must report 0 or the toast lies.

Match rewards fire exactly once on entering `RoundResults`, behind a flag cleared when that
state is left. `Net.rewardSummary` is a **receipt**: every line reports a write that has
already happened, so a client that drops the packet loses a screen, never a reward.

The XP curve is in `Shared.Progression` and is shared for a real reason — the HUD draws the
same bar the server rolls over, and two curves diverge on the first balance tweak.

---

## Config

[`src/shared/Config.luau`](src/shared/Config.luau) holds every tunable number in the game
and is **frozen at load**. A service that wrote `Config.Round.Duration` at runtime would
desync every client silently, because the client's copy is a different table on a different
machine. The freeze turns that into an error at the assignment.

It is shared, not server-only, because the HUD must draw a bar that empties in exactly
`DrainDuration` while the server decides when sprinting is allowed. **Nothing secret may go
in it** — ReplicatedStorage ships it to every client.

---

## What lives where, for this game specifically

| | Owned by | Edited in |
|---|---|---|
| Services, controllers, shared modules | Rojo | VS Code |
| The six maps, spawns, pickup nodes, camera rails | Studio | Studio (`ServerStorage.Maps`) |
| Every ScreenGui under `StarterGui.Screens` | Studio | Studio |
| Headband, grenade bodies, pickup marker | Studio | Studio (`ServerStorage.Assets`) |
| Teams, `ActiveMap`, grenades, smoke, code billboards | neither — created at runtime | — |

The client **never builds a GUI tree in Luau**. It finds the authored elements and drives
them. The only runtime-created visuals are the ones a ScreenGui cannot contain: the code
`BillboardGui` on a character, the menu `BlurEffect`, the avatar `WorldModel`, and the
full-screen flash.
