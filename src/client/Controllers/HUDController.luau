--!strict
--[[
	Drives the authored HUD: the match clock, the score block, the elimination
	banner, the kill toasts and the transient notice line.

	Still the worked example of the two rules that matter most on the client,
	and it is now the file that needs BOTH halves of the second one:

	  1. Author the ScreenGui in Studio, find it here. Rojo mounts scripts, not
	     instances -- StarterGui is yours (ARCHITECTURE.md, "The map"), so this
	     controller never builds a label, it only fills ones that already exist.
	     The single thing it creates is a clone of the authored ToastTemplate,
	     which is the entire reason that template is authored.
	  2. STATE comes from an observer, EVENTS come from a packet, and the HUD
	     draws both. The clock and the scores are state: they are read off the
	     round replica through MatchController, so a player who joins eight
	     minutes into a round gets the same HUD as one who was here at the
	     start. A kill and a notice are things that HAPPENED: they arrive as
	     packets, because a player who was not here missed nothing
	     (NETWORKING-AND-DATA.md, "which pipe?").

	Nothing here is required: with no HUD authored, this warns once and goes
	idle rather than erroring on every tick.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local Match = require(ReplicatedStorage.Shared.Match)
local MatchController = require(script.Parent.MatchController)
local Motion = require(script.Parent.Parent.UI.Motion)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("HUDController")

local player = Players.LocalPlayer

-- The key this player occupies in Round.Players. Constant for the session.
local selfKey = Match.playerKey(player.UserId)

-- How long to wait for the authored screen before deciding there isn't one.
-- Bounded so a missing GUI surfaces as one warning instead of hanging Start().
local SCREEN_TIMEOUT = 10

local TIMER_INTERVAL = 0.5
-- 99:59. A clock cannot render more than this, and string.format("%02d", inf)
-- throws rather than printing something merely wrong.
local MAX_CLOCK_SECONDS = 99 * 60 + 59

local NOTICE_HOLD = 2.5
local SHAKE_PIXELS = 10
local SHAKE_CYCLES = 3

local BANNER_HOLD = 1.1

-- Hold + the "smooth" preset's 0.28s fade lands a toast at ~1.8s on screen.
local TOAST_HOLD = 1.5

-- Events buffered while no HUD is bound. See `deferred`.
local MAX_PENDING = 4

--[[
	Config.Modes has fixed fields (TeamDeathmatch, FreeForAll), so indexing it
	with a mode id read off the replica is a --!strict error even though that
	is exactly the shape the round hands us. One narrow, documented cast at
	that boundary beats keeping a second copy of the kill goals in this file.

	Through `any`, and that step is not decoration: a sealed table of named
	fields and a string-indexed map are unrelated types to Luau, so the direct
	cast is itself the --!strict error it was written to avoid. The `any` stops
	on this line -- the annotated local is what every read below goes through,
	so nothing downstream inherits it.
]]
local MODE_CONFIG: { [string]: { KillGoal: number } } = Config.Modes :: any

-- Net.notice's `kind` picks the colour; the wording and the styling are ours
-- (Net.luau, notice).
local NOTICE_COLORS: { [string]: Color3 } = {
	Info = Color3.fromRGB(232, 236, 245),
	Warn = Color3.fromRGB(245, 196, 96),
	Error = Color3.fromRGB(232, 96, 96),
}

--[[
	Net.codeResult's short tags, spelled out. Wording lives here precisely so
	rewording one costs no server deploy and no bandwidth (Net.luau).

	"NotPlaying" covers both "you are not in the round" and "they are not in
	the round yet" (KillService), so the text must not claim which -- naming
	the wrong party is worse than naming neither.
]]
local REJECTION_TEXT: { [string]: string } = {
	RoundInactive = "NO ROUND IN PROGRESS",
	NotPlaying = "NOT IN PLAY",
	BadCode = `CODES ARE {Config.Code.Digits} DIGITS`,
	NoSuchCode = "NO SUCH CODE",
	Self = "THAT IS YOUR OWN CODE",
	Friendly = "THAT IS A TEAMMATE",
	Protected = "THEY JUST SPAWNED",
	RateLimited = "SLOW DOWN",
}

-- Drives one authored element between its Studio look (0) and invisible (1).
type Fader = (alpha: number) -> ()

type Toast = {
	frame: GuiObject,
	timer: thread?,
	handle: Motion.Handle?,
}

-- Net.codeResult's payload, named so the handler below fits on one line.
type CodeResult = {
	accepted: boolean,
	reason: string,
	targetName: string,
	cash: number,
	experience: number,
}

type Hud = {
	timer: TextLabel,
	teamScores: GuiObject,
	redName: TextLabel,
	redValue: TextLabel,
	blueName: TextLabel,
	blueValue: TextLabel,
	soloScores: GuiObject,
	youName: TextLabel,
	youValue: TextLabel,
	leaderName: TextLabel,
	leaderValue: TextLabel,
	notice: TextLabel,
	-- The notice's authored position, captured once so an interrupted shake
	-- always has a true origin to return to.
	noticeHome: UDim2,
	crosshair: GuiObject,
	toastList: GuiObject,
	toastTemplate: GuiObject,
	banner: GuiObject,
	bannerLabel: TextLabel,
	bannerFade: Fader,
}

local HUDController = {}

-- nil whenever there is no bound HUD: before Start finds one, and in the gap
-- on every respawn while PlayerGui is re-cloned. Every write site checks it.
local ui: Hud? = nil
-- Set when there is no HUD to find. Stops `deferred` buffering forever.
local abandoned = false

local pending: { () -> () } = {}

local toasts: { Toast } = {}
-- UIListLayout leaves equally-ordered children to sort by name, and every
-- clone shares the template's name -- so the order toasts happened in only
-- survives if it is written down.
local toastOrder = 0

local noticeHandle: Motion.Handle? = nil
local noticeHold: thread? = nil
local shakeHandle: Motion.Handle? = nil

local bannerHandle: Motion.Handle? = nil
local bannerHold: thread? = nil

--[[
	Walks a "A/B/C" path from a root, or nil at the first missing step.

	FindFirstChild, never WaitForChild: this runs against a tree that has
	already replicated in full, and a typo in a path should be reported by
	bind() in one warning rather than parking the caller for ten seconds.
]]
local function resolve(root: Instance?, path: string): Instance?
	local current: Instance? = root
	for _, name in string.split(path, "/") do
		if current == nil then
			return nil
		end
		current = current:FindFirstChild(name)
	end
	return current
end

--[[
	A replicated counter, as a drawable whole number.

	Everything counted here comes off the round replica, which the dev console
	can reshape at runtime, so the static type is a promise nobody kept. NaN is
	rejected BEFORE the comparison that assumes a comparable number, and the
	clamp -- not the floor -- is what makes infinity finite
	(quality-gate.md trap #8).
]]
local function count(value: any): number
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	return math.clamp(math.floor(value), 0, 1e9)
end

--[[
	A replicated server timestamp, used only as a tiebreak key.

	Unusable values become +inf so they LOSE every tiebreak. An unset
	LastKillAt must not promote somebody above a player whose time is real.
]]
local function timestamp(value: any): number
	if type(value) ~= "number" or value ~= value then
		return math.huge
	end
	return value
end

local function displayName(entry: Match.RoundPlayer): string
	local name = entry.DisplayName
	return if type(name) == "string" and name ~= "" then name else "PLAYER"
end

local function clock(seconds: number): string
	if type(seconds) ~= "number" or seconds ~= seconds then
		return "00:00"
	end
	local total = math.clamp(math.floor(seconds), 0, MAX_CLOCK_SECONDS)
	return string.format("%02d:%02d", total // 60, total % 60)
end

--[[
	Config is shared so this reads "37 / 100" rather than "37" (Config.luau
	header). Goal 0 means a mode Config does not know about, and a bare number
	beats "37 / 0".
]]
local function withGoal(value: number, goal: number): string
	if goal <= 0 then
		return `{value}`
	end
	return `{value} / {goal}`
end

--[[
	Builds the fade for one authored element, capturing what Studio authored
	as the fully-visible end.

	Lerping from the authored transparency rather than from 0 is the point: a
	toast authored at BackgroundTransparency 0.2 that faded from 0 would pop to
	opaque on the first frame of its own fade-out. Capture happens once, at
	bind or at clone time, never mid-fade -- re-reading the property while a
	fade is running would bake a half-faded value in as the new "visible".
]]
local function fader(frame: GuiObject, label: TextLabel): Fader
	local baseBackground = frame.BackgroundTransparency
	local baseText = label.TextTransparency
	return function(alpha: number)
		frame.BackgroundTransparency = baseBackground + (1 - baseBackground) * alpha
		label.TextTransparency = baseText + (1 - baseText) * alpha
	end
end

--=========================================================================
-- TOASTS
--=========================================================================

--[[
	Destroys one toast and forgets it, from any path -- expiry, a rebind, or a
	fade that was cancelled. Every exit runs through here, which is what makes
	"a toast is always destroyed" true rather than merely usual: an undestroyed
	clone is a leak that grows for the whole round, one per kill.
]]
local function discardToast(toast: Toast)
	local index = table.find(toasts, toast)
	if index ~= nil then
		table.remove(toasts, index)
	end

	if toast.timer ~= nil then
		task.cancel(toast.timer)
		toast.timer = nil
	end
	if toast.handle ~= nil then
		toast.handle.cancel()
		toast.handle = nil
	end

	toast.frame:Destroy()
end

local function clearToasts()
	-- Backwards: discardToast removes from the array being walked.
	for index = #toasts, 1, -1 do
		discardToast(toasts[index])
	end
end

local function pushToast(text: string)
	local hud = ui
	if hud == nil then
		return
	end

	local frame = hud.toastTemplate:Clone()
	-- bind() proved the template carries this label, so the clone does too.
	local label = frame:FindFirstChild("TextLabel") :: TextLabel

	label.Text = text
	-- Colour, font and size stay exactly as authored. Studio owns the look;
	-- this owns which toasts exist and for how long.
	frame.Visible = true
	toastOrder += 1
	frame.LayoutOrder = toastOrder
	frame.Parent = hud.toastList

	local fade = fader(frame, label)
	local toast: Toast = { frame = frame, timer = nil, handle = nil }
	table.insert(toasts, toast)

	toast.timer = task.delay(TOAST_HOLD, function()
		-- Cleared before the work, so discardToast can never task.cancel the
		-- thread it is currently running on.
		toast.timer = nil
		toast.handle = Motion.value(0, 1, "smooth", fade, function()
			toast.handle = nil
			discardToast(toast)
		end)
	end)
end

--=========================================================================
-- NOTICE LINE
--=========================================================================

local function stopShake()
	if shakeHandle ~= nil then
		shakeHandle.cancel()
		shakeHandle = nil
	end

	local hud = ui
	if hud ~= nil then
		-- Motion.value does not call back for a cancelled tween, so the reset
		-- belongs here: an interrupted shake would otherwise leave the line a
		-- few pixels off-centre for the rest of the session.
		hud.notice.Position = hud.noticeHome
	end
end

local function stopNotice()
	if noticeHandle ~= nil then
		noticeHandle.cancel()
		noticeHandle = nil
	end
	if noticeHold ~= nil then
		task.cancel(noticeHold)
		noticeHold = nil
	end
	stopShake()
end

local function showNotice(kind: string, message: string)
	local hud = ui
	if hud == nil then
		return
	end

	-- A second notice replaces the first outright. Two fades racing on one
	-- label is a line that flickers instead of a message that reads.
	stopNotice()

	local label = hud.notice
	label.Text = message
	label.TextColor3 = NOTICE_COLORS[kind] or NOTICE_COLORS.Info

	noticeHandle = Motion.tween(label, { TextTransparency = 0 }, "snappy", function()
		noticeHandle = nil
		noticeHold = task.delay(NOTICE_HOLD, function()
			noticeHold = nil
			noticeHandle = Motion.tween(label, { TextTransparency = 1 }, "smooth", function()
				noticeHandle = nil
			end)
		end)
	end)
end

--[[
	A short nudge on the notice line, for a rejected code.

	Offsets are in pixels, not scale, so the nudge is the same physical size
	whatever the label's width resolves to. The sine is damped to exactly zero
	at alpha 1, which means a run that completes lands back on the authored
	position with no snap -- and a run that is cancelled is put back by
	stopShake instead.
]]
local function shakeNotice()
	local hud = ui
	if hud == nil then
		return
	end

	stopShake()

	local label = hud.notice
	local home = hud.noticeHome

	shakeHandle = Motion.value(0, 1, "smooth", function(alpha)
		local offset = math.sin(alpha * math.pi * 2 * SHAKE_CYCLES) * (1 - alpha) * SHAKE_PIXELS
		label.Position = UDim2.new(home.X.Scale, home.X.Offset + math.round(offset), home.Y.Scale, home.Y.Offset)
	end, function()
		shakeHandle = nil
	end)
end

--=========================================================================
-- ELIMINATION BANNER
--=========================================================================

local function stopBanner()
	if bannerHandle ~= nil then
		bannerHandle.cancel()
		bannerHandle = nil
	end
	if bannerHold ~= nil then
		task.cancel(bannerHold)
		bannerHold = nil
	end

	local hud = ui
	if hud ~= nil then
		-- Same reasoning as stopShake: a cancelled fade never reaches its
		-- completion, so hiding the banner has to happen on this path too or
		-- an interrupted flash stays on screen at whatever opacity it reached.
		hud.banner.Visible = false
	end
end

local function flashBanner(targetName: string)
	local hud = ui
	if hud == nil then
		return
	end

	-- Two kills in quick succession replace the banner rather than queue it.
	-- The second name is the one worth reading.
	stopBanner()

	local fade = hud.bannerFade
	hud.bannerLabel.Text = `ELIMINATED {targetName}`
	hud.banner.Visible = true

	-- Motion.value applies `from` synchronously before playing, so the banner
	-- is already invisible on the frame it becomes Visible -- no flash of the
	-- authored pose.
	bannerHandle = Motion.value(1, 0, "pop", fade, function()
		bannerHandle = nil
		bannerHold = task.delay(BANNER_HOLD, function()
			bannerHold = nil
			bannerHandle = Motion.value(0, 1, "smooth", fade, function()
				bannerHandle = nil
				hud.banner.Visible = false
			end)
		end)
	end)
end

--=========================================================================
-- SCORES AND PHASE
--=========================================================================

--[[
	The Free For All leader: most kills, ties broken by who got there first.

	Two things this deliberately does NOT do. It does not name anyone on a
	board of zeros -- Luau leaves dictionary iteration order undefined, so "the
	top of an all-zero table" is whoever the hash happened to yield, and the
	label would change between refreshes for no reason a player could see. And
	it does not break ties arbitrarily: LastKillAt ascending is the same
	tiebreak the mode itself uses (Match.luau, design brief 44), so the HUD
	names the player who would actually win.
]]
local function leaderOf(players: { [string]: Match.RoundPlayer }): (string?, string, number)
	local bestKey: string? = nil
	local bestName = ""
	local bestKills = 0
	local bestAt = math.huge

	for key, entry in players do
		local kills = count(entry.Kills)
		if kills <= 0 then
			continue
		end

		local at = timestamp(entry.LastKillAt)
		if kills > bestKills or (kills == bestKills and at < bestAt) then
			bestKey = key
			bestName = displayName(entry)
			bestKills = kills
			bestAt = at
		end
	end

	return bestKey, bestName, bestKills
end

local function refreshScores()
	local hud = ui
	if hud == nil then
		return
	end

	--[[
		One boolean drives both Visible flags, so "TeamScores in TDM,
		SoloScores in FFA, never both" is a property of the code rather than an
		invariant two separate writers have to remember.

		UsesTeams, never a comparison against a mode id -- that fork is what
		the flag exists for (Match.luau, GameMode).
	]]
	local usesTeams = MatchController.usesTeams()
	hud.teamScores.Visible = usesTeams
	hud.soloScores.Visible = not usesTeams

	local round = MatchController.getRound()
	if round == nil then
		-- The replica has not landed. The authored placeholder text stands
		-- until it does, which is a beat, not a bug.
		return
	end

	local mode = MODE_CONFIG[MatchController.getModeId()]
	local goal = if mode ~= nil then mode.KillGoal else 0

	if usesTeams then
		local scores = round.Scores
		if scores == nil then
			return
		end
		hud.redValue.Text = withGoal(count(scores.Red), goal)
		hud.blueValue.Text = withGoal(count(scores.Blue), goal)
		return
	end

	local players = round.Players
	if players == nil then
		return
	end

	local entry = MatchController.getSelfEntry()
	hud.youValue.Text = withGoal(if entry ~= nil then count(entry.Kills) else 0, goal)

	local leaderKey, leaderName, leaderKills = leaderOf(players)
	if leaderKey == nil then
		hud.leaderName.Text = "LEADER"
		hud.leaderValue.Text = "0"
		return
	end

	-- Being your own leader is the one case where the row has to say something
	-- different, or it reads as a second player with your exact score.
	-- A display name is left in the player's own spelling.
	hud.leaderName.Text = if leaderKey == selfKey then "YOU LEAD" else leaderName
	hud.leaderValue.Text = `{leaderKills}`
end

--[[
	The crosshair belongs to the phase, not the screen: HUD stays up through
	the killcam so the scores and the clock keep reading, and a crosshair over
	a corpse-cam is aiming at nothing.
]]
local function applyPhase(phase: Match.PlayerPhase)
	local hud = ui
	if hud == nil then
		return
	end
	hud.crosshair.Visible = phase == "Playing"
end

--[[
	The clock, repainted about twice a second.

	Not RenderStepped: this is a clock, not an animation, and sixty repaints a
	second to move a digit once a second is fifty-nine wasted. Not once a
	second either -- a 1s tick beats against the very boundary it is trying to
	show, so the readout visibly sticks and then skips two. Sampling at twice
	the displayed resolution keeps every repaint within half a second of the
	truth, which is all a whole-second readout can ask for.
]]
local function timerLoop()
	while true do
		local hud = ui
		if hud ~= nil then
			hud.timer.Text = clock(MatchController.secondsRemaining())
		end
		task.wait(TIMER_INTERVAL)
	end
end

--=========================================================================
-- PACKETS
--=========================================================================

--[[
	Replays a packet once there is somewhere to draw it.

	A small buffer, not a log. PlayerGui is wiped and re-cloned on every
	respawn, so there is a window each spawn with no label to write into, and
	a notice landing in it would otherwise vanish with no trace. Capped
	because "no HUD was ever authored" must not turn this into a table that
	grows for the whole session -- and when the cap bites, the oldest message
	is the one worth losing.
]]
local function deferred(replay: () -> ())
	if ui ~= nil then
		replay()
		return
	end
	if abandoned then
		return
	end

	if #pending >= MAX_PENDING then
		table.remove(pending, 1)
	end
	table.insert(pending, replay)
end

local function drain()
	if #pending == 0 then
		return
	end
	-- Swap first: a replay that defers again must land in the new list, not
	-- in the one being walked.
	local queued = pending
	pending = {}
	for _, replay in queued do
		replay()
	end
end

local function onCodeResult(data: CodeResult)
	if not data.accepted then
		local text = REJECTION_TEXT[data.reason]
		if text == nil then
			-- A tag this build does not know about. Say something true rather
			-- than print a wire tag at the player.
			log.debug(`unmapped codeResult reason "{data.reason}"`)
			text = "CODE REJECTED"
		end
		showNotice("Warn", text)
		shakeNotice()
		return
	end

	flashBanner(if data.targetName ~= "" then data.targetName else "TARGET")

	--[[
		Zero is a legitimate amount -- a killer whose profile failed to load is
		granted nothing and the kill still stands (KillService) -- and "+0
		CASH" is a receipt for nothing. The balance itself arrives through the
		profile replica; these toasts only name what this kill was worth.
	]]
	if data.cash > 0 then
		pushToast(`+{data.cash} CASH`)
	end
	if data.experience > 0 then
		pushToast(`+{data.experience} XP`)
	end
end

--=========================================================================
-- BINDING
--=========================================================================

local function bind(gui: ScreenGui): Hud?
	local root = gui:FindFirstChild("Root")
	if root == nil then
		log.warn("HUD has no Root -- a screen's content lives under a single root frame (UIController.luau)")
		return nil
	end

	local missing: { string } = {}

	local function need(path: string, className: string): Instance?
		local found = resolve(root, path)
		if found ~= nil and found:IsA(className) then
			return found
		end
		table.insert(missing, `{path} ({className})`)
		return nil
	end

	local timer = need("TopBar/TimerHolder/TimerLabel", "TextLabel")
	local teamScores = need("TopBar/TeamScores", "GuiObject")
	local redName = need("TopBar/TeamScores/RedScore/NameLabel", "TextLabel")
	local redValue = need("TopBar/TeamScores/RedScore/ValueLabel", "TextLabel")
	local blueName = need("TopBar/TeamScores/BlueScore/NameLabel", "TextLabel")
	local blueValue = need("TopBar/TeamScores/BlueScore/ValueLabel", "TextLabel")
	local soloScores = need("TopBar/SoloScores", "GuiObject")
	local youName = need("TopBar/SoloScores/YouScore/NameLabel", "TextLabel")
	local youValue = need("TopBar/SoloScores/YouScore/ValueLabel", "TextLabel")
	local leaderName = need("TopBar/SoloScores/LeaderScore/NameLabel", "TextLabel")
	local leaderValue = need("TopBar/SoloScores/LeaderScore/ValueLabel", "TextLabel")
	local notice = need("NoticeLabel", "TextLabel")
	local crosshair = need("Crosshair", "GuiObject")
	local toastList = need("ToastList", "GuiObject")
	local toastTemplate = need("ToastTemplate", "GuiObject")
	-- Checked, not kept: pushToast clones the template and reads the label off
	-- the clone. Proving it here means a template with no label fails once, at
	-- bind, instead of on the first kill of the round.
	need("ToastTemplate/TextLabel", "TextLabel")
	local banner = need("EliminationBanner", "GuiObject")
	local bannerLabel = need("EliminationBanner/TextLabel", "TextLabel")

	if #missing > 0 then
		--[[
			All or nothing, in one warning. Half a HUD -- a clock with no
			scores, a toast list with no template -- is harder to diagnose than
			a HUD that says exactly which authored paths it could not find, and
			every write site below would need its own nil check to allow it.
		]]
		log.warn(`HUD.Root is missing {table.concat(missing, ", ")} -- driving nothing until the authored tree matches`)
		return nil
	end

	local hud: Hud = {
		timer = timer :: TextLabel,
		teamScores = teamScores :: GuiObject,
		redName = redName :: TextLabel,
		redValue = redValue :: TextLabel,
		blueName = blueName :: TextLabel,
		blueValue = blueValue :: TextLabel,
		soloScores = soloScores :: GuiObject,
		youName = youName :: TextLabel,
		youValue = youValue :: TextLabel,
		leaderName = leaderName :: TextLabel,
		leaderValue = leaderValue :: TextLabel,
		notice = notice :: TextLabel,
		noticeHome = (notice :: TextLabel).Position,
		crosshair = crosshair :: GuiObject,
		toastList = toastList :: GuiObject,
		toastTemplate = toastTemplate :: GuiObject,
		banner = banner :: GuiObject,
		bannerLabel = bannerLabel :: TextLabel,
		bannerFade = fader(banner :: GuiObject, bannerLabel :: TextLabel),
	}

	-- Constant text, written once per bind. Both the word and the hue come
	-- from Match.TEAMS so there is one source for each -- and the word is set
	-- as well as the colour because roughly one player in twelve cannot
	-- separate these two hues reliably (Match.luau, TeamDefinition).
	hud.redName.Text = Match.TEAMS.Red.DisplayName
	hud.redName.TextColor3 = Match.TEAMS.Red.Color
	hud.blueName.Text = Match.TEAMS.Blue.DisplayName
	hud.blueName.TextColor3 = Match.TEAMS.Blue.Color
	hud.youName.Text = "YOU"

	return hud
end

--[[
	Finds the HUD, drives it, and re-finds it for the rest of the session.

	The loop is not defensive padding. StarterGui.ResetPlayerGuiOnSpawn is on
	by default and wipes PlayerGui on EVERY respawn -- and in this game a
	player respawns every few seconds -- so the HUD bound at join is a
	destroyed instance from the first death onwards, and every write to it
	after that lands on nothing, silently and with no error to find. UIController
	re-registers the replacement screen for exactly the same reason.

	Destroying:Wait() rather than a connection: there is no handle to forget to
	disconnect, and this thread has nothing else to do in the meantime.
]]
local function attachLoop()
	local playerGui = player:WaitForChild("PlayerGui")

	while true do
		-- WaitForChild, not a direct index: PlayerGui is populated by
		-- replication from StarterGui, so the screens are reliably absent for
		-- the first frames even when they HAVE been authored.
		local screens = playerGui:WaitForChild("Screens", SCREEN_TIMEOUT)
		local gui = if screens ~= nil then screens:WaitForChild("HUD", SCREEN_TIMEOUT) else nil

		if gui == nil or not gui:IsA("ScreenGui") then
			log.warn(`no PlayerGui.Screens.HUD after {SCREEN_TIMEOUT}s -- the HUD will not be drawn`)
			abandoned = true
			table.clear(pending)
			return
		end

		local bound = bind(gui)
		if bound == nil then
			-- bind() named what is missing. The copy re-cloned on the next
			-- respawn is the same authored tree, so retrying would only repeat
			-- the same warning on a loop.
			abandoned = true
			table.clear(pending)
			return
		end

		ui = bound
		applyPhase(MatchController.getPhase())
		refreshScores()
		drain()

		gui.Destroying:Wait()

		-- Cleared BEFORE the teardown, so the stop functions below skip the
		-- instances that are on their way out and only cancel the handles.
		ui = nil
		clearToasts()
		stopNotice()
		stopBanner()
	end
end

function HUDController.Init()
	--[[
		Registered here, not in Start. A packet fired at a client whose
		listener does not exist yet is dropped, not queued (Net.luau,
		devRequestAccess) -- and Start does not run until every Init has
		finished, which is a window a notice can genuinely land in.

		The labels these write into do not exist this early either. `deferred`
		holds the handful that can arrive first, so registering early costs
		nothing.
	]]
	Net.notice.listen(function(data)
		deferred(function()
			showNotice(data.kind, data.message)
		end)
	end)

	Net.codeResult.listen(function(data)
		deferred(function()
			onCodeResult(data)
		end)
	end)
end

function HUDController.Start()
	--[[
		Registered once, here rather than inside attachLoop: a rebind after a
		respawn must not stack a second observer on every path. They fire into
		`ui`, which is nil until the loop binds one, and attachLoop calls
		refreshScores itself after each bind to pick up whatever it missed.

		Three paths, one recompute. Both rows depend on the mode, the scores
		and the roster, and recomputing the block is cheaper than reasoning
		about which half a given write touched.
	]]
	MatchController.observe({ "ModeId" }, refreshScores)
	MatchController.observe({ "Scores" }, refreshScores)
	MatchController.observe({ "Players" }, refreshScores)

	-- Registered before the first read below, so a change landing between the
	-- two is applied twice rather than missed. applyPhase is idempotent.
	MatchController.onPhaseChanged(applyPhase)

	task.spawn(timerLoop)

	-- Parks for the session. The Loader spawns every Start(), so nothing is
	-- waiting on this one to return.
	attachLoop()
end

return HUDController
