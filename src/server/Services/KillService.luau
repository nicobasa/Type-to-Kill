--!strict
--[[
	The core mechanic: one player types another player's four-digit code, and
	the player wearing that code dies.

	THIS FILE DECIDES NOTHING IT CAN LOOK UP. It owns exactly one question --
	"is this submission a legal kill, right now?" -- and every fact behind that
	question belongs to the service that owns it: RoundService for the match
	state, ParticipantService for who is in the round, CodeService for who owns
	a code, TeamService for sides, SpawnService for protection. The elimination
	is the only mutation made here; the score, the reward and the respawn are
	handed straight back out to the services that own those.

	ORDER IS THE SECURITY DESIGN, not a style choice.

	  1. The rate limiter runs before anything else -- before the state read,
	     before a log line, before the code is so much as looked at. Answering
	     a flood is what turns a flood into an amplifier: every inbound packet
	     would buy an outbound send, and a logged drop merely relocates the
	     flood into the output panel (RateLimiter.luau). A limited packet is
	     dropped in silence. Net.luau lists a "RateLimited" reason tag; the
	     server deliberately never sends it, for exactly that reason.

	  2. The ladder below then runs in a fixed order that is NOT cheapest
	     first. A player submitting during the results screen is told the round
	     is over, even though checking the string's shape would have been
	     cheaper. The tag a player gets back should name the reason they
	     actually failed, not whichever cheap test happened to trip first.

	WHAT A FAILURE IS ALLOWED TO SAY

	A refusal never carries the target's name. The reason tags themselves leak
	next to nothing -- codes are drawn above heads, so anyone who can see a
	player can already read their code, and "Protected" only confirms what the
	headband already showed. A NAME is different in kind: it ties a code to an
	identity for a submitter who cannot see its owner, which turns guessing
	four digits into a roster scan. Only an accepted kill names anyone, and by
	then the killer has earned the answer.

	NO PER-PLAYER STATE. There is no `{[Player]: T}` table here, so there is
	nothing to clear on PlayerRemoving: every submission is resolved from the
	services above, fresh, with no memory between packets. The one piece of
	per-player memory involved is the rate limiter's timestamps, and those live
	inside RateLimiter, which clears every limiter it has handed out on
	PlayerRemoving so that no caller can forget to.

	Every require below is direct. Nothing in the contract's dependency table
	points back at KillService -- it is a leaf, the end of the call graph -- so
	no cycle exists here and no deferred require is needed.

	LevelService is the one require here that the contract's dependency table
	does not draw an arrow for. It is there for the killer's Level on the kill
	card, and it is safe to add: LevelService requires only DataService, which
	requires nothing in Services/, so the graph stays acyclic -- and
	RewardService, which KillService already requires, pulls LevelService in
	anyway. See the Net.killed block below for why the round replica row is the
	wrong source for that number.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local CodeService = require(script.Parent.CodeService)
local Config = require(ReplicatedStorage.Shared.Config)
local CosmeticsService = require(script.Parent.CosmeticsService)
local LevelService = require(script.Parent.LevelService)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local ParticipantService = require(script.Parent.ParticipantService)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local RewardService = require(script.Parent.RewardService)
local RoundService = require(script.Parent.RoundService)
local ScoreService = require(script.Parent.ScoreService)
local SpawnService = require(script.Parent.SpawnService)
local SprintService = require(script.Parent.SprintService)
local TeamService = require(script.Parent.TeamService)
local Validate = require(ServerStorage.Modules.Validate)

local log = Log.new("KillService")

--[[
	The ceilings of the wire fields involved: Net.codeResult carries cash and
	experience as uint32, Net.killed carries the killer's level and kills as
	uint16. See toUnsigned().
]]
local MAX_UINT16 = 65535
local MAX_UINT32 = 4294967295

-- The killer's Level when their profile is not loaded -- a brand-new join, or
-- a session that failed to load. 1 is the profile template's starting Level,
-- so the card reads like a fresh account rather than "Lv.0".
local FALLBACK_LEVEL = 1

--[[
	Module scope, and one limiter for the whole service. RateLimiter keys by
	player internally, so a table here would only duplicate what it already
	holds -- and duplicate the cleanup obligation along with it.
]]
local submitLimit = RateLimiter.new(Config.RateLimit.CodeSubmit)

--[[
	The tags Net.codeResult carries back. Short tags, never sentences: the
	client maps each to display text, so rewording "NO SUCH CODE" costs no
	server deploy and no bandwidth (Net.luau, codeResult).
]]
type Reason =
	"Killed"
	| "RoundInactive"
	| "NotPlaying"
	| "Stunned"
	| "BadCode"
	| "NoSuchCode"
	| "Self"
	| "Friendly"
	| "Protected"

--[[
	This player's Humanoid if they are alive, nil in every other case.

	FindFirstChildOfClass, never WaitForChild: this runs inside a packet
	handler, and waiting on the character of a player sitting in the menu parks
	that handler for a character that is never coming -- one parked thread per
	packet, which is the exact cost the rate limiter above exists to deny.

	The Humanoid is the authority on liveness here, not the round replica's
	`Alive` flag. That flag is a mirror SpawnService writes, and between a
	character dying and that write landing it still reads true. Trusting it
	would hand out kills on corpses.
]]
local function livingHumanoid(player: Player): Humanoid?
	local character = player.Character
	if character == nil then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return nil
	end

	--[[
		NaN is rejected explicitly, before the comparison that assumes a
		comparable number. `Health <= 0` is FALSE for NaN, so a NaN would read
		as ALIVE here and let a corpse both take and deal a kill.

		Not a theoretical input: Humanoid.Health replicates from the client that
		owns the character, which makes it one of the very few numbers in this
		file an exploiter can shape directly (quality-gate.md trap #8). A
		Humanoid whose health is not a number is not a Humanoid this service is
		willing to call alive.
	]]
	local health = humanoid.Health
	if health ~= health or health <= 0 then
		return nil
	end
	return humanoid
end

--[[
	Clamp a number into what its wire field can actually hold.

	These fields are fixed-width UNSIGNED integers. A negative, fractional or
	NaN value -- from a service that failed its own validation, or from a row
	the dev console reshaped -- would be written as one anyway and arrive as a
	vast positive number: "+4294967286 CASH" in a toast. Flooring and clamping
	makes the worst case a wrong-but-plausible figure instead. NaN is rejected
	first and explicitly, because it fails every comparison that follows
	(quality-gate.md trap #8).
]]
local function toUnsigned(value: number, max: number): number
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	return math.clamp(math.floor(value), 0, max)
end

--[[
	Refuse a submission. targetName is always empty and the amounts always
	zero -- see the header: a failure names nobody.
]]
local function refuse(player: Player, reason: Reason)
	Net.codeResult.sendTo({
		accepted = false,
		reason = reason,
		targetName = "",
		cash = 0,
		experience = 0,
	}, player)
end

--[[
	The ladder. Every rung returns, so nothing below a refusal runs, and
	nothing between the elimination and SpawnService.onDeath yields -- a
	submission is resolved inside one frame, with no window for a second one to
	interleave.
]]
local function onSubmitCode(data: { code: string }, killer: Player)
	if not RoundService.isRoundActive() then
		refuse(killer, "RoundInactive")
		return
	end

	--[[
		isPlaying, not isInRound. A player in Killcam is still IN the round --
		they hold a scoreboard row and are owed a respawn (Match.luau) -- but a
		corpse must not be able to type its way to a kill during the five
		seconds it spends watching one.
	]]
	if not ParticipantService.isPlaying(killer) then
		refuse(killer, "NotPlaying")
		return
	end

	if livingHumanoid(killer) == nil then
		refuse(killer, "NotPlaying")
		return
	end

	--[[
		A frag stun takes typing away too. TypeModeController already blocks
		the digits and says why, but that is the client's picture of the
		rule; this is the rule. A modified client that sends a code anyway is
		refused here before the code is even looked at.
	]]
	if SprintService.isStunned(killer) then
		refuse(killer, "Stunned")
		return
	end

	--[[
		ByteNet guaranteed a string arrived. It cannot guarantee four digits,
		and a near miss that reached the code table would be a free kill --
		"0047" and 47 are the same number and different codes, so anything that
		has been through tonumber() has already lost the identity
		(Validate.luau).
	]]
	if not Validate.code(data.code, RoundService.getCodeDigits()) then
		refuse(killer, "BadCode")
		return
	end

	local target = CodeService.resolve(data.code)
	if target == nil then
		refuse(killer, "NoSuchCode")
		return
	end

	--[[
		Typing your own headband. Refused rather than treated as a suicide: a
		player's own code is the one number they are guaranteed to be able to
		read, which makes this the most likely honest mistake in the game, and
		answering a typo with a death is a punishing answer to it.
	]]
	if target == killer then
		refuse(killer, "Self")
		return
	end

	local targetHumanoid = livingHumanoid(target)
	if targetHumanoid == nil or not ParticipantService.isPlaying(target) then
		refuse(killer, "NotPlaying")
		return
	end

	--[[
		UsesTeams, never a comparison of the mode id against a literal --
		Match.GameMode carries this flag precisely so the TDM/FFA fork is read
		from data at every call site rather than re-decided at each one.
	]]
	local mode = RoundService.getTeamMode()
	if mode.UsesTeams then
		local killerTeam = TeamService.getTeam(killer)
		local targetTeam = TeamService.getTeam(target)

		--[[
			A team mode with a teamless player on either end means someone has
			not finished joining. NotPlaying rather than Friendly, because that
			is the honest answer: there is no team to credit the point to, and
			no side for the victim to have been on.
		]]
		if killerTeam == nil or targetTeam == nil then
			refuse(killer, "NotPlaying")
			return
		end

		if killerTeam == targetTeam then
			refuse(killer, "Friendly")
			return
		end
	end

	--[[
		Last rung on purpose. Spawn protection is the only refusal here that
		expires on its own, so the useful answer is the one a player gets by
		retyping the same code a second later.
	]]
	if SpawnService.isProtected(target) then
		refuse(killer, "Protected")
		return
	end

	--[[
		The elimination, applied through the Humanoid rather than by asking
		SpawnService to despawn. Every death in the game then arrives at
		Humanoid.Died -- including the ones nobody submitted a code for, like a
		fall -- so SpawnService has one path to maintain instead of two.
		onDeath is still called explicitly at the end of this function, because
		the Died signal cannot carry a killer and the killcam has to name one.

		This write is also the double-kill guard: it lands synchronously, so a
		second submission of the same code in the same frame -- from a different
		killer, who has their own rate-limit budget -- finds a dead Humanoid at
		the liveness rung above and is refused. Two killers cannot be paid for
		one death.
	]]
	targetHumanoid.Health = 0

	ScoreService.recordKill(killer, target)

	-- Every kill costs the killer their code: whoever read it during the fight
	-- has to read the new one (CodeService.reroll).
	CodeService.reroll(killer)

	--[[
		The grants happen inside awardKill; what comes back is a receipt of
		writes that have already landed, which is the only reason it is safe to
		put them in a packet (Net.luau, codeResult). Zero is a legitimate
		answer -- a killer whose profile is not loaded is granted nothing -- and
		the kill stands either way, because a reward that could not be written
		is not a reason to un-kill somebody.
	]]
	local cash, experience = RewardService.awardKill(killer)

	Net.codeResult.sendTo({
		accepted = true,
		reason = "Killed",
		targetName = target.DisplayName,
		cash = toUnsigned(cash, MAX_UINT32),
		experience = toUnsigned(experience, MAX_UINT32),
	}, killer)

	--[[
		Sent after recordKill so killerKills includes the kill that just
		happened: the card reads "12 KILLS", not 11.

		Level comes from LevelService, the owner of the number, and NOT from the
		round replica row. The row looks like the tempting source -- it is what
		the scoreboard renders -- but RoundService.addPlayerEntry seeds `Level =
		1` and no service in the contract ever writes that field again, so
		reading it here would put a permanent "Lv.1" on every kill card in the
		game. Reading the profile is the only source that is actually correct
		today, and it still agrees with the row on the day somebody claims that
		field and starts mirroring it.

		respawnAt is absolute server time, never a countdown (Match.luau), and
		is computed from the same Config.Killcam.Duration that SpawnService
		schedules the respawn from. That duplication is deliberate: the packet
		needs a deadline, the contract gives SpawnService no getter for one, and
		recomputing it locally from the shared constant beats inventing a helper
		on a service somebody else is writing right now.
	]]
	-- `if ... ~= nil`, not `or`: getLevel returns number?, and `or` would also
	-- swallow a legitimate 0 if the curve ever starts there.
	local storedLevel = LevelService.getLevel(killer)
	local killerLevel = if storedLevel ~= nil then storedLevel else FALLBACK_LEVEL

	Net.killed.sendTo({
		killerUserId = killer.UserId,
		killerName = killer.DisplayName,
		killerLevel = toUnsigned(killerLevel, MAX_UINT16),
		killerKills = toUnsigned(ScoreService.getKills(killer), MAX_UINT16),
		killerTitle = CosmeticsService.getEquippedTitle(killer),
		respawnAt = workspace:GetServerTimeNow() + Config.Killcam.Duration,
	}, target)

	SpawnService.onDeath(target, killer)

	log.debug(`{killer.Name} killed {target.Name}`)
end

local KillService = {}

function KillService.Init()
	Net.submitCode.listen(function(data, player)
		-- ByteNet types the sender as optional because both sides share one
		-- listen signature; on the server it is always present.
		if player == nil then
			return
		end

		--[[
			THE FIRST LINE OF THE HANDLER, deliberately. See the header: a
			rate-limited packet is dropped before it can cost a state read, a
			log line or a reply.
		]]
		if not submitLimit.allow(player) then
			return
		end

		onSubmitCode(data, player)
	end)
end

function KillService.Start()
	log.info("ready")
end

return KillService
