--!strict
--[[
	Every tunable number in Type to Kill, in one place.

	A plain module -- the name ends in neither Service nor Controller, so the
	Loader ignores it (ARCHITECTURE.md Recipe 3). Require it directly.

	Shared rather than server-only, and that is not laziness: the HUD has to
	draw a stamina bar that empties in exactly StaminaDrainDuration seconds
	while the server decides when sprinting is actually allowed, and the score
	HUD has to know the kill goal to render "37 / 100" while the server owns
	the real comparison. Two copies of those numbers is two curves that
	diverge on the first balance tweak -- the same argument Progression.luau
	makes for the XP curve, and a genuine both-sides need
	(ARCHITECTURE.md:12), not an exception to the shared-folder rule.

	Nothing here is a secret. A value a client must not know (a drop table, a
	server-side cooldown that gates a reward) does NOT belong in this file --
	ReplicatedStorage ships it to every client, exploiters included. Today
	every value below is either cosmetic, a timing the client must render, or
	a limit the server re-checks anyway.

	FROZEN at the bottom. A service that writes Config.Round.Duration at
	runtime would desync every client silently -- the client's copy is a
	separate table on a separate machine, and no write here replicates. The
	freeze turns that from a bug you find in a playtest into an error at the
	assignment.
]]

local Config = {
	--[[
		The match loop. Durations are seconds.

		IntermissionDuration is the LOBBY dwell before voting opens -- long
		enough for the results overlay to finish and the menu camera to settle,
		short enough that an empty-ish server still cycles.
	]]
	Round = {
		Duration = 600,
		IntermissionDuration = 4,
		VotingDuration = 15,
		MapLoadingMinDuration = 1.5,
		WaitingToPlayDuration = 5,
		ResultsDuration = 5,
		-- A round starts with this many players present. 1 keeps solo Studio
		-- testing working; raise it for a live server if empty rounds hurt.
		MinPlayers = 1,
	},

	Killcam = {
		Duration = 5,
	},

	--[[
		Codes are strings, never numbers, everywhere in this codebase.
		"0047" is a legal code and tonumber("0047") is 47 -- the leading zeros
		ARE the identity, so anything that round-trips through a number has
		already lost it (Validate.code enforces the shape).
	]]
	Code = {
		--[[
			There is no fixed code length: it is the round's ruleset
			(Config.GameModes[id].CodeDigits), published in the round replica
			as GameModeId. Read it through RoundService.getCodeDigits on the
			server and MatchController.getCodeDigits on the client, never by
			caching a number at module load -- it changes between rounds.
		]]

		--[[
			How close another player has to be before the server will tell you
			their code at all.

			This is the anti-exploit measure, and it is worth being precise
			about what it can and cannot do. A code has to be READABLE on
			screen, so it has to reach the client, so an exploiter can always
			read the ones they are being shown -- there is no arrangement of
			this game in which that is false. What this range removes is the
			attack that actually matters: without it every client holds every
			code in the server, and one line of exploit code kills everybody.
			With it, a dumper holds only the codes of players they could
			already have read off the screen.

			Set comfortably ABOVE the distance at which four digits are
			legible, so it never costs a legitimate kill -- it is a bound on
			bulk collection, not a gameplay rule. Lower it and you start
			refusing kills a player could honestly have made; raise it toward
			the map size and it stops bounding anything.
		]]
		VisibleRange = 110,

		-- How often the server recomputes who can see whom. Deliberately not
		-- per frame: it is a distance test against a walking player, and a
		-- fifth of a second of staleness is invisible next to the time it
		-- takes a human to read a number and type it.
		VisibilityInterval = 0.2,

		-- How long a code stays visible after line of sight to it breaks. A
		-- post or a door frame that crosses the line for one sweep would
		-- otherwise blink the number out from under a player who is reading
		-- it. Short enough that stepping behind a real wall still hides you
		-- about as fast as a human could notice.
		SightGrace = 0.4,
	},

	Spawn = {
		ProtectionDuration = 2,
		-- Candidate spawns within this radius of a living enemy are skipped
		-- when a safer one exists. Not a hard rule: a crowded map must still
		-- spawn someone rather than fail.
		EnemyAvoidRadius = 40,
	},

	--[[
		The rulesets (Match.GAME_MODES), by id. Extreme is Standard with twice
		the digits: eight to read and type instead of four, off the same plate,
		so every code is legible from about half as far away. That is the whole
		difference, and it is meant to be.

		Adrenaline is Standard with a boosted sprint: walking is the normal
		pace, sprinting is faster than normal, and stamina never drains, so
		the sprint never stops. The stamina bar is drawn as a colourful boost
		while it runs (StaminaController).

		WalkSpeed / SprintSpeed are the Humanoid speeds for the ruleset, written
		only by SprintService. InfiniteStamina turns the drain off on both
		sides (SprintService, and StaminaController's prediction).

		SignWidthScale widens the headband's plate (and the fallback billboard)
		for the ruleset, so a longer code still fits on ONE line at the SAME
		text size as four digits. The label is TextScaled, so on a plate of the
		original width eight digits would shrink instead. 2.1 is measured for
		"1234 5678" in GothamBlack: eight digit widths plus the group space is
		about 2.1 times the width of four.
	]]
	GameModes = {
		Standard = {
			CodeDigits = 4,
			SignWidthScale = 1,
			WalkSpeed = 16,
			SprintSpeed = 30,
			InfiniteStamina = false,
		},
		Extreme = {
			CodeDigits = 8,
			SignWidthScale = 2.1,
			WalkSpeed = 16,
			SprintSpeed = 30,
			InfiniteStamina = false,
		},
		Adrenaline = {
			CodeDigits = 4,
			SignWidthScale = 1,
			WalkSpeed = 16,
			SprintSpeed = 40,
			InfiniteStamina = true,
		},
	},

	--[[
		The team modes (Match.TEAM_MODES), by id. The key MUST equal the mode
		id: HUDController and ScoreService look the goal up by it.

		Four teams split the lobby four ways, so each side scores more slowly
		than in two teams; its goal is lower to keep rounds about as long.
	]]
	TeamModes = {
		TwoTeams = {
			KillGoal = 100,
		},
		FourTeams = {
			KillGoal = 60,
		},
		FreeForAll = {
			KillGoal = 30,
		},
	},

	Teams = {
		-- Max allowed difference between the largest and the smallest team the
		-- mode plays with. A team that would widen it past this locks.
		MaxImbalance = 2,
	},

	Voting = {
		MapChoices = 3,
	},

	--[[
		Stamina, expressed as DURATIONS rather than rates, because the design
		is stated in durations: "four seconds of sprint from full", "three
		seconds from empty to full". Rates are derived once, in StaminaService
		and StaminaController, from these.

		RegenDelay is a HOLD, not a ramp: stamina must sit at exactly the value
		it stopped at for this long. Anything else and a player who taps sprint
		repeatedly gains or loses stamina they never spent.
	]]
	Stamina = {
		Max = 100,
		DrainDuration = 4,
		RegenDelay = 1,
		FullRegenDuration = 3,
		-- Fraction of Max below which the bar shows its red warning pulse.
		LowThreshold = 0.25,
		-- Stamina must climb back to this fraction before sprint can re-engage
		-- after hitting zero. Without it, sprint flickers on and off one frame
		-- at a time at the bottom of the bar.
		ResumeThreshold = 0.15,
	},

	Toolbar = {
		SlotCount = 2,
	},

	--[[
		Grenades. Fuse is time from leaving the hand to detonation.

		Flash has two bands. Inside CloseRange, line of sight alone is enough --
		a flash at your feet blinds you whichever way you face. Between
		CloseRange and MaxRange it also has to be roughly in front of you:
		ViewConeDegrees is the FULL cone width, so 120 means anything within 60
		degrees of your look vector counts. Generous on purpose; demanding
		precise aim to be flashed reads as the flash being broken.
	]]
	Flash = {
		FuseDuration = 1.6,
		CloseRange = 30,
		MaxRange = 80,
		ViewConeDegrees = 120,
		FullDuration = 0.5,
		FadeDuration = 2,
	},

	Smoke = {
		FuseDuration = 1.6,
		Duration = 15,
		-- ~5-6 Roblox characters across. A character is about 5 studs wide, so
		-- a 14-stud radius is a 28-stud cloud -- big enough to break a sightline
		-- rather than decorate one.
		Radius = 14,
		-- How long the cloud takes to bloom in and to dissipate out. Inside
		-- Duration, not added to it.
		GrowDuration = 1,
		FadeDuration = 2,
	},

	--[[
		The frag. No damage, like every grenade in this game: it stuns. Every
		enemy inside Radius with a clear line to the blast is frozen in place
		for StunDuration seconds (SprintService.stun). Teammates and the
		thrower are never affected.

		Radius sits between the smoke cloud (14) and the flash's close band
		(30): wide enough that a frag landing near a pair catches both, small
		enough that it has to be thrown at someone rather than into a room.

		A stunned player also cannot type a code (KillService refuses it, and
		TypeModeController says why), so a stun is also three seconds in which
		they cannot kill anyone.
	]]
	Frag = {
		FuseDuration = 1.6,
		Radius = 20,
		StunDuration = 3,
	},

	--[[
		The shock grenade. Thrown and fused like the frag, and it picks its
		targets the same way (enemies only, line of sight, never someone under
		spawn protection), over a wider Radius. It does not freeze: every
		enemy it catches is SLOWED to SlowSpeed for SlowDuration seconds --
		clearly slower than walking (Config.GameModes WalkSpeed, 16) without
		being a crawl -- and cannot sprint at all until it wears off. A second
		shock restarts the slow at its full length; slows never stack.
	]]
	Shock = {
		FuseDuration = 1.6,
		Radius = 30,
		SlowDuration = 3,
		SlowSpeed = 9,
	},

	--[[
		The impulse grenade: a movement tool. It STICKS to the first surface it
		touches (Config.Throw's flight, stopped dead on contact) and, when the
		fuse runs out, launches every player within Radius -- the thrower and
		teammates included, on purpose, so it can be used to fly -- straight
		away from it: along the line from the grenade to their
		HumanoidRootPart. Standing right above it sends you straight up.

		Launch speed falls off with distance: MaxSpeed at the grenade, MinSpeed
		at the edge of Radius. A player on the ground gets at least GroundLift
		of upward speed so the floor's grip cannot swallow a sideways launch; a
		player already in the air gets the launch exactly as computed. No
		ragdoll and no loss of control: it is only a change of velocity.

		A wall between the grenade and a player blocks the launch, like every
		other blast here.
	]]
	Impulse = {
		FuseDuration = 1.6,
		Radius = 30,
		MaxSpeed = 150,
		MinSpeed = 35,
		GroundLift = 35,
	},

	--[[
		How every grenade flies. One table for all of them: the three kinds
		differ in what they do when they go off, not in how they are thrown.

		CHARGE. Holding the throw input fills a bar beside the crosshair over
		ChargeTime seconds; releasing throws at a speed between MinSpeed (a quick
		tap -- the throw the game has always had) and MaxSpeed (a full second's
		hold). The client reports only how full the bar was, 0..1, and the server
		clamps it: a full-strength throw is something anybody can do by holding
		for a second, so a forged 1.0 gains nothing.

		THE FLIGHT IS SIMULATED, NOT PHYSICS (server Modules/Ballistics.luau).
		Gravity is Workspace.Gravity; collisions are found by sweeping a sphere
		of ProjectileRadius along the path with Spherecast, so a grenade can
		never tunnel through a thin wall at speed.

		  Restitution      the share of the speed INTO a surface that comes back
		                   out of it on a bounce (0 dead stop, 1 perfect bounce).
		  BounceFriction   the share of the speed ALONG a surface kept through a
		                   bounce. Below 1 is what makes a grenade that hits the
		                   floor at a shallow angle skid to a stop instead of
		                   skating off at nearly full speed.
		  RollDeceleration studs/s^2 lost while rolling on the ground. High on
		                   purpose: a grenade should settle within a few studs of
		                   where it lands, not roll across the map.
		  SettleSpeed      a bounce slower than this does not bounce at all; the
		                   grenade stays on the surface and rolls. Stops the
		                   endless micro-hops a pure restitution model produces.

		BarDelay hides the bar for a quick tap, so a tap does not flash the bar
		on screen for a single frame.
	]]
	Throw = {
		MinSpeed = 70,
		MaxSpeed = 140,
		ChargeTime = 1,
		BarDelay = 0.1,
		ProjectileRadius = 0.45,
		Restitution = 0.35,
		BounceFriction = 0.55,
		RollDeceleration = 60,
		SettleSpeed = 6,
	},

	Pickups = {
		-- Seconds before a taken pickup returns.
		RespawnDelay = 20,
	},

	--[[
		Cash and XP. Every number here is granted by the SERVER only, and every
		grant runs through CashService/LevelService, which bound it again.
	]]
	Rewards = {
		KillCash = 10,
		KillExperience = 25,

		--[[
			Every team mode, two or four sides. Win is sole first place; Draw is
			a tie for first; everything else is a Loss. With four teams that is
			deliberately blunt: second of four earns what last of four does, so
			the only thing worth playing for is first.
		]]
		Teams = {
			WinCash = 150,
			WinExperience = 300,
			DrawCash = 100,
			DrawExperience = 200,
			LossCash = 60,
			LossExperience = 120,
		},

		FreeForAll = {
			FirstCash = 200,
			FirstExperience = 400,
			SecondCash = 120,
			SecondExperience = 240,
			ThirdCash = 80,
			ThirdExperience = 160,
			ParticipationCash = 40,
			ParticipationExperience = 80,
		},
	},

	--[[
		Minimum seconds between two accepted packets of each kind, per player.

		These are floors on a HUMAN action, not on the network. CodeSubmit at
		0.12 is roughly eight submissions a second -- far past what anyone can
		type, and far below what a flood needs to be to cost the server
		anything. Tune down before tuning up: a limit a real player can feel is
		worse than one an exploiter can live with, because the exploiter is
		already bounded by the validation that follows.
	]]
	RateLimit = {
		CodeSubmit = 0.12,
		Vote = 0.25,
		TeamRequest = 0.5,
		JoinRequest = 0.5,
		ItemAction = 0.2,
		SettingWrite = 0.25,
		-- Buying, opening and equipping (CosmeticsService). One limiter each,
		-- so buying a case and then opening it are not the same budget.
		ShopAction = 0.3,
	},
}

--[[
	Depth-first freeze. table.freeze is shallow, so freezing only the root
	would leave Config.Round.Duration writable -- which is precisely the
	nested field anything would actually try to write.
]]
local function deepFreeze(value: { [any]: any })
	for _, child in value do
		if type(child) == "table" then
			deepFreeze(child)
		end
	end
	table.freeze(value)
end

deepFreeze(Config)

return Config
