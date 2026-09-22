# Gameplay

Companion to [ARCHITECTURE.md](ARCHITECTURE.md) (where files go) and
[NETWORKING-AND-DATA.md](NETWORKING-AND-DATA.md) (how values move). This one covers the
game itself: the match loop, the four-digit code, and how to add a map, a mode or an item
without touching anything else.

---

## The one-paragraph version

Every living player wears a number on their head: four digits in Standard, eight in
Extreme. You kill someone by reading their number and typing it. The server owns every
code, decides every kill, and is the only thing that can grant Cash or XP. Rounds are ten
minutes on one of six maps, with two teams, four teams or Free For All, all picked by vote.

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
State · GameModeId · TeamModeId · MapId · PhaseEndsAt
Scores { Red, Blue, Green, Yellow }   -- every team, 0 when the mode does not use it
Vote   { MapChoices, MapVotes, GameModeVotes, TeamModeVotes }
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

## The code

`CodeService` owns a pool. On every spawn a player is drawn a **new** code, zero-padded, a
string, unique among living players. Its length is the round's game mode (4 in Standard, 8
in Extreme), read at every draw; codes never outlive a round, so a pool never mixes lengths.
An eight-digit code is printed on the plate as `1234 5678` so it reads as two numbers; the
space is presentation only and is never typed. On death, respawn, leave or round end it goes back.
Every kill also costs the killer their code (`CodeService.reroll`): anyone who read it
during the fight has to read the new one. The victim, now in the killcam, never sees it — a
player with no code of their own is shown no codes at all.

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

Every round is decided by **three votes**, in order: the map, the **game mode** and the
**team mode**. The two mode axes are independent:

| Axis | Ids (`Match`) | What it changes |
|---|---|---|
| Game mode (ruleset) | `Standard`, `Extreme`, `Adrenaline` | Everything in `Config.GameModes[id]`: code length `CodeDigits` (4 / 8 / 4), the headband plate's `SignWidthScale`, the pace `WalkSpeed` / `SprintSpeed`, and `InfiniteStamina` |

**Adrenaline** is Standard with a boosted sprint: walking is the normal 16, sprinting is 40
instead of 30, and stamina never drains, so the sprint never stops. While a player sprints,
their stamina bar turns into a vivid rainbow, tilted diagonally and flowing left. A wide,
half-transparent diagonal white glint sweeps the other way at a steady pace, faster than
the colours. The bar also kicks up in size once as the
sprint starts (`StaminaController`). The rainbow is one continuous sweep of hue, run a
little faster through the greens so green doesn't look longer than the rest. It is drawn
once, in a rotated strip of identical segments that slides, so the motion is smooth. The
glint is a rotated frame, not a rotated `UIGradient`: on a bar this wide a gradient's
rotation squeezes the band to a sliver. Colours change continuously, and the glint passes
any spot about once every 2.2 s. The speeds are set only by
`SprintService`, like every speed in the game, and `StaminaController`'s prediction skips the
drain too, so the bar never dips and snaps back.
| Team mode | `TwoTeams`, `FourTeams`, `FreeForAll` | Sides (`Teams`), whether they use team spawns (`TeamSpawns`), the kill goal (`Config.TeamModes[id].KillGoal`) |

Both are published in the round replica (`GameModeId`, `TeamModeId`) at MapLoading, in one
write, before any code for the round can exist. Read them through
`RoundService.getTeamMode()` / `getCodeDigits()` on the server and the `MatchController`
getters on the client — never cache the code length, it changes between rounds.

`TeamMode.UsesTeams` is what forks the game — team select, friendly-fire rejection, which
score HUD is drawn, how placement is computed. Read that field and `Teams`; never compare an
id to a literal at a call site.

**A team outside the mode's `Teams` list does not exist for the round.** Green is a real
team, but `ParticipantService.onRequestTeam` refuses it in a two-team round
(`Match.modeHasTeam`), and `TeamService.assign` checks the same list again. A client with no
Green button is not a defence against one that sends "Green" anyway.

**Four teams spawn from the shared FFA pool** (`TeamSpawns = false`), because the maps only
author Red and Blue spawns. `SpawnService.livingEnemyPositions` treats only your own team as
friends, so the enemy-distance check still keeps you away from the other three.

**Winning a team round:** sole first place wins, a tie for first is a draw, everything else
is a loss (`RewardService.teamOutcome`, mirrored by the results headline). Second of four
pays what last of four does, on purpose.

`TeamService` keeps the authoritative counts in its own table, **not** in
`Team:GetPlayers()`, and re-runs the balance check *inside* `assign()`. That re-check is
the entire point: two players hitting the same button in the same frame must not both pass
a check that was true before either of them joined. `Config.Teams.MaxImbalance` (2) is the
most the largest and smallest of the mode's teams may differ; a side that would widen it
past that locks. `TeamSelectController.wouldExceedImbalance` mirrors the rule on the
client — change them together.

The client greys out a locked side, but that is presentation. The server decides, and a
rejection comes back as `Net.notice`.

### Adding a mode

A **team mode**: add it to `Match.TEAM_MODES` and `TEAM_MODE_ORDER` (with its `Teams` and
`TeamSpawns`), and give it a `KillGoal` in `Config.TeamModes` under the same id. A team it
uses that is not Red/Blue/Green/Yellow needs a `Match.TEAMS` entry, a `<Team>Button` under
`TeamSelect.Root.Panel.Options` and a `<Team>Score` under `HUD.Root.TopBar.TeamScores`
(both layouts fill their width with whichever are visible).

A **game mode**: add it to `Match.GAME_MODES` and `GAME_MODE_ORDER`, and give it a
`CodeDigits` in `Config.GameModes`. A code longer than eight also needs more
`TypeMode.Root.Panel.Digits.Digit<N>` boxes; only the shortest ruleset's boxes are required,
so a missing extra box costs only the longer ruleset.

The vote panel lists every entry of both ORDER lists; there is no cap.

---

## Items

Three throwables, in [`src/shared/Items.luau`](src/shared/Items.luau). Two toolbar slots,
`Config.Toolbar.SlotCount`.

The slots array is **always** `SlotCount` long, with `""` for empty — never a table with
holes, because `#` on one of those is undefined in Luau.

Grenades are created, owned and simulated **by the server**, so the thrower cannot teleport
one. The client contributes the two things the server cannot know: the camera's look
direction, and how long the throw was charged. No grenade deals damage.

**Throwing is charged.** Holding the throw input fills a small white bar beside the
crosshair (`HUD.Root.ChargeBar`) over `Config.Throw.ChargeTime` (1 s). Releasing throws
along the camera's look direction, looking up throws up. The speed runs from `MinSpeed`
(a quick tap, the original throw) to `MaxSpeed` (a full charge). The client sends only the
charge, 0..1; the server clamps it, so a forged full charge gains nothing anyone can't get by
holding for a second.

**The flight is simulated, not Roblox physics** (`src/server/Modules/Ballistics.luau`). The
part is anchored and moved every Heartbeat. Gravity is `Workspace.Gravity`, and collisions
are found by sweeping a sphere along the path with `Spherecast`, so a fast grenade can't
tunnel through a thin wall. Bounces lose energy (`Restitution`, and `BounceFriction` along
the surface), and on the ground it rolls against a high `RollDeceleration`, so it settles
within a few studs of where it lands. Grenades pass through characters, so a landing never
depends on where somebody happened to step. Every tuning number is in `Config.Throw`.

**Flashbang.** The server checks range and raycasts line of sight, then tells the clients
that passed. The *view cone* test is the client's, because the server knows where a
character faces, not where its camera looks. That split is honest rather than lax: no
server can force a client to render white pixels, so the cone test gains an exploiter
nothing that ignoring the packet outright would not. Everything enforceable — who is close
enough, who is behind a wall — is enforced.

**Smoke.** A server-created cloud instance, so every player's vision is blocked by the same
cloud in the same place. A client-rendered cloud would let one player see through smoke
another player is blind in.

**Frag.** No damage: it stuns. Every enemy within `Config.Frag.Radius` (20 studs) with a
clear line to the blast (to their head or their root; bodies are not cover) is frozen for
`Config.Frag.StunDuration` (3 s): no walking, sprinting, jumping, or turning the body, so
they cannot run or turn their code away. They can still look around.

- **A stunned player cannot type a code.** `KillService` refuses the submit (`"Stunned"`),
  which is the rule; `TypeModeController` blocks the digits and swaps the panel's
  `PromptLabel` to `STUNNED — CAN'T TYPE`, which is the explanation. The panel still opens
  and closes with T as normal.

- **Never the thrower or their team.** The thrower's team is read when the fuse is lit, so
  it holds even if they leave mid-flight. In a team mode with no team to read, the blast
  stuns nobody. Spawn-protected players are skipped too.
- **`SprintService.stun` applies it**, because SprintService is the only writer of
  `WalkSpeed`. A second writer would fight the sprint: the next Shift press would hand a
  stunned player their speed back. A second frag **restarts** the stun at 3 s; it never
  adds to what was left. A death ends it.
- **Everyone sees it:** yellow sparks over the torso, created on the server inside the
  character so it replicates with no packet. On the torso, not the head, so it never covers
  the code plate. `ServerStorage.Assets.StunEffect` replaces the built-in sparks if authored.
- **The stunned player is told** with `Net.stunned`: a yellow screen edge and a
  `STUNNED 2.4` countdown (`EffectsController`). Presentation only; the freeze is already
  applied on the server. `EffectsController.isStunned` / `onStunChanged` are the client's
  one answer to "am I stunned?", so the countdown and the locked keypad cannot disagree.

**Shock.** Thrown and fused like the frag. It uses the same targeting
(`GrenadeService.enemiesInBlast`: enemies only, line of sight, never someone
spawn-protected) over a wider `Config.Shock.Radius` of 30 studs. It does not freeze. Every
enemy caught is **slowed** to `Config.Shock.SlowSpeed` (9, against a walking 16) for
`Config.Shock.SlowDuration` (3 s), and **cannot sprint** for that time: a running sprint is
cancelled and a new one refused.

- **`SprintService.slow` applies it**, for the frag's reason. A second shock restarts the
  slow; a death ends it. A player frozen by a frag stays frozen, and the stun's expiry picks
  up a slow that is still running.
- **Everyone sees it:**
  - a blue energy sphere grows to the full radius and fades once (`ShockBlast`);
  - blue-white arcs, sparks and a steady blue glow sit on each shocked torso
    (`ShockEffect`, overridable by `ServerStorage.Assets.ShockEffect`).
- **The shocked player is told** with `Net.shocked`: a blue screen edge and a
  `SHOCKED -- NO SPRINT 2.4` countdown, just under where the stun's sits.
- **Typing is not blocked**, unlike the frag. The shock takes your legs, not your hands.
- One smoke pickup node per map was turned into a shock node (the `ItemId` attribute under
  each map's `Markers`). The admin panel can give it (GIVE ITEM) and apply it
  (`SHOCK 3S`, `GrenadeService.shockPlayer`).

**Impulse.** A movement tool, not a weapon. It **sticks** to the first surface it touches,
floor or wall (`Ballistics` in sticky mode; `GrenadeKind.Sticky`), and when the fuse runs
out it launches **every** player in the round within `Config.Impulse.Radius` (30 studs):
the thrower and teammates too, on purpose, so players can blast themselves around the map.

- **Direction:** along the line from the grenade to the player's `HumanoidRootPart`.
  Standing on top of it sends you straight up; it on a wall beside you sends you sideways.
- **Strength:** falls off with distance, from `MaxSpeed` (150) at the grenade to `MinSpeed`
  (35) at the edge.
- **In the air**, the launch is applied exactly. **On the ground**, it gets at least
  `GroundLift` (35) of upward speed, so the floor's grip can't swallow a sideways push.
- **No ragdoll, no loss of control:** only a velocity change. The humanoid goes to Freefall
  and steers like any jump.
- **The client applies it.** The server computes the velocity
  (`GrenadeService.detonateImpulse`) and sends it with `Net.impulse`, and the player's own
  `ImpulseController` writes it to their root. A client owns its character's physics, so a
  velocity the server wrote would be overwritten on the next step.
- A wall between the grenade and a player shields them. Everyone sees a magenta
  `ImpulseBlast` swell.
- Measured in Play: at its own feet it launched the thrower straight up at 137 studs/s, 50
  studs high. Just ahead of the thrower, it sent them 29 studs back and 26 up.
- One flashbang node per map was turned into an impulse node. The admin panel's GIVE ITEM
  lists it automatically.

Pickups are authored per map (a node's `ItemId` attribute), so a frag only appears on maps
whose nodes say `FragGrenade`.

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

Rates are derived from those durations on both sides; nothing hardcodes a rate. The walk
and sprint speeds are the round's ruleset (`Config.GameModes[id].WalkSpeed` / `SprintSpeed`),
and a ruleset with `InfiniteStamina` (Adrenaline) never drains at all.

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
`MENU_SCREENS` — currently `MainMenu`, `TeamSelect`, and the menu's overlays `Inventory`,
`Shop` and `Settings`. Leaving a screen out of that list was a real bug twice: the menu
closed, the override came back, and the player was left looking at a panel (TeamSelect,
then the Shop) they could not move the mouse to click.

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

## Cosmetics: cases and titles

The catalog is [`src/shared/Cosmetics.luau`](src/shared/Cosmetics.luau): rarities, the
titles, and the cases. `CosmeticsService` is the only thing that grants any of it.

- **Buying** (`Net.buyCase`): the price is the catalog's, the Cash is taken with
  `CashService.trySpend` (refuses rather than going negative), and the case goes into the
  profile's `Inventory` as a counted stack through `InventoryService`. If the case cannot be
  added after the Cash was taken, the Cash is given back.
- **Opening** (`Net.openCase`): `InventoryService.tryRemove` takes one case (and is the
  "do you have one?" check), the server rolls, and writes the title into `Titles`. A title
  already owned is a **duplicate**: nothing new, and the rarity's `DuplicateRefund` in Cash
  instead. `Net.caseOpened` is a receipt for the reveal animation only.
- **Equipping** (`Net.equipTitle`, `""` to unequip): only a title the player owns.

Every handler is one slice with no yield between the check and the write, so a double
click cannot buy one case for the price of two or open one case twice.

**A roll** picks a rarity by `Weight`, then a title uniformly inside it. The rarity weights
are **one table for every case**, so a new case uses the same percentages. The odds are
**shared on purpose**: Roblox requires the odds of a paid random item to be visible before
purchase. The server still makes every roll with its own `Random`.

**The Shop is a catalog**, a grid of cards built from `Cosmetics.CASES`. Each card has its
picture (`Case.Image`, `""` shows a placeholder until it has one), a Cash button, a Robux
button, and an **eye button** that opens a grid of everything the case can drop
(`Cosmetics.contents`). The drop odds are one popup behind the **"?"** in the Shop's
header: it shows on hover, and a tap toggles it for touch.

**The Inventory shows only what the player owns**: cases, and cosmetics in the Cosmetics
tab, each as a grid of square cards. The Cosmetics tab is meant for every kind of cosmetic;
titles are just the only kind so far.

**Opening a case** happens in two acts:

1. **A vertical reel.** Titles fall through a window and stop with the rolled one on the
   centre line. The reel starts moving only once the server's receipt is in, so it knows
   where to stop. The filler rows are rolled on the client with the same weights; they are
   decoration, never a decision.
2. **The result.** The reel fades out and the item is shown large in the middle, with
   EQUIP (a duplicate is still owned, so it can be equipped too), OK, and **OPEN
   ANOTHER (N LEFT)** while the player still has more of that case.

**Where it lives in the profile:** `Inventory[caseId]` (count), `Titles[titleId] = true`
(a set — its own field, never under `Inventory`, which is `{[id]: count}` and would read a
nested table as 0), and `EquippedTitle` (`""` for none).

**Other players see only the equipped title**, and only on the killcam card: the profile is
private, so `KillService` copies it into `Net.killed.killerTitle`
(`CosmeticsService.getEquippedTitle`, which re-checks ownership).

**How a title looks** is data in the catalog (`Solid`, `Gradient`, `Flow`, `Shimmer`) and is
drawn by `src/client/UI/TitleStyle.luau` everywhere a title appears — the main-menu card,
the killcam card, the Inventory and the reveal. Every animation is a slow slide (a second
or more per cycle), never a flash.

**The Robux button is built but not wired.** Pressing it says Robux purchases are coming
soon. Wiring it is `MarketplaceService:PromptProductPurchase` in `ShopController` and a
`ProcessReceipt` on the server whose grant is `InventoryService.add(player, caseId, 1)`.

To add a title: one entry in `Cosmetics.TITLES`. To add a case: one entry in
`Cosmetics.CASES` (the Shop shows the first case today).

---

## Admin panel

`AdminService` (server) and `AdminController` (client, `Screens.Admin`). It opens with
**M** (or F2) or with the shield button next to Settings in the main menu. Both show only
for an admin, and the same key closes it; the key is ignored while typing in a text box.

Mid-round the admin **stays in first person**: the camera is not touched. The cursor is freed
only because the panel's `CloseButton` is `Modal`, which unlocks the mouse exactly while the
panel is open, and it locks again on close.

**Who is an admin:** the UserIds in [`src/server/Modules/AdminList.luau`](src/server/Modules/AdminList.luau),
plus any in the Creator Dashboard config `developers` (`{ "userIds": [...] }`), which is
read live, so an admin can be added without a publish. The client asks
(`Net.adminRequestAccess`) and is told (`Net.adminAccess`), but that answer only hides a
button. **Every admin packet is re-checked on the server:** rate limit first, then
`isAdmin`, then validation. Every accepted action goes into a 60-entry audit log (the Log
tab).

**Editing data** (`Net.adminEdit`, one `op` per packet, all validated in
`AdminService.applyEdit`):

| Op | Does |
|---|---|
| `SetCash`, `SetLevel`, `SetExperience` | clamped numbers |
| `SetCases` | the count of one `Cosmetics.CASES` case (0 removes it) |
| `GrantTitle`, `RevokeTitle`, `EquipTitle` | titles (a revoked equipped title is unequipped) |
| `SetField` | any existing scalar at a dotted path, and only with the same type |
| `ResetData` | the profile back to the template |

A player **in this server** is edited through `DataService`, so the change replicates at
once. A player who is **offline or in another server** is never written directly: the edit
is sent with ProfileStore `MessageAsync` and applied by `applyEdit` when that profile is
next loaded (the `MessageHandler` in `DataService`). This is always safe, even mid-session
elsewhere. **Never use `SetAsync` or `Steal` for this**: that overwrites the live session and
loses whatever that server saves next.

**Player actions** (`Net.adminPlayerAction`, only for players in this server): Kill, Send
to menu, Stun (1–30 s), Give item (any `Items.LIST` entry), Set team (only a team the
current mode has), Kick (with a reason, never yourself), Bring, Go to, and New code.

**Round control** (`Net.adminServerAction`): Skip phase, End round, Restart round, and a
**next-round override** (map, game mode and team mode, each either forced or left to the
vote). *Force next round* keeps the vote but pins whatever was forced. *Change map now*
restarts at once and **skips the vote**: whatever was left open keeps the current mode
(or, for the map, is random). The override is used once, then cleared.

**Announcements** are filtered by `TextService` for broadcast before anyone sees them.
They show on their own screen (`Screens.Announcement`) for 6 s, over the menu and the round
alike.

**Anything a player can own must be in the panel** (the CLAUDE.md invariant). Catalog lists
build themselves: cases, titles, give-item buttons and team buttons come from
`Cosmetics`, `Items` and `Match`. So a new case, title or item needs nothing extra. A **new
field or currency** needs:

- a new op in `applyEdit`, which also covers offline players;
- a row in `Screens.Admin` → `PlayersPage.Data`;
- a line in `AdminController` that binds that row.

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
`BillboardGui` on a character, the menu `BlurEffect`, the avatar `WorldModel`, the
full-screen flash and stun overlay, and the one `UIGradient` (`TitleGradient`) that
`TitleStyle` puts on an authored label to colour a cosmetic title — which gradient a label
needs is player data, not layout.
