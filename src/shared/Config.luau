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
		Digits = 4,

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

	Modes = {
		TeamDeathmatch = {
			KillGoal = 100,
		},
		FreeForAll = {
			KillGoal = 30,
		},
	},

	Teams = {
		-- Max allowed |Red - Blue|. The larger team locks at this difference.
		MaxImbalance = 2,
	},

	Voting = {
		MapChoices = 3,
		-- The UI is built for three columns even though there are two modes
		-- today, so a third mode needs no layout work.
		MaxModeChoices = 3,
	},

	Movement = {
		WalkSpeed = 16,
		SprintSpeed = 30,
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
		ThrowSpeed = 70,
	},

	Smoke = {
		FuseDuration = 1.6,
		Duration = 15,
		-- ~5-6 Roblox characters across. A character is about 5 studs wide, so
		-- a 14-stud radius is a 28-stud cloud -- big enough to break a sightline
		-- rather than decorate one.
		Radius = 14,
		ThrowSpeed = 70,
		-- How long the cloud takes to bloom in and to dissipate out. Inside
		-- Duration, not added to it.
		GrowDuration = 1,
		FadeDuration = 2,
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

		TeamDeathmatch = {
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
