--!strict
--[[
	What a dead player looks at until they respawn: an over-the-shoulder camera
	on whoever killed them, plus a card naming them.

	THE PACKET IS THE ONLY SOURCE FOR THE CARD

	Net.killed carries the killer's name, level and kill count denormalised
	(Net.luau says why), and this controller reads nothing else. Looking any of
	it up would be looking it up at the worst possible moment: the killer can
	quit the instant after the kill, and a card that blanks out because they did
	is worse than no card. The UserId is used for two things only -- the
	thumbnail request, and finding a character to point at if one is still there.

	THE CAMERA OVERRIDE IS A GLOBAL LOCK, SO ITS RELEASE IS THE WHOLE FILE

	CameraController.override lifts the first-person lock for as long as anyone
	holds it. Leak one release and the player spends the rest of the session
	with no first-person view and no arms -- there is no second chance, no
	respawn that fixes it, and nothing in the log. Every exit is therefore routed
	through one finish(), which clears the session before it does any work and
	releases after a pcall'd teardown (Luau has no finally --
	.claude/rules/quality-gate.md, Gate 2). The exits are: the respawn deadline,
	the character coming back, the player's phase leaving Killcam (respawn, or
	they left the match), the match leaving RoundActive (the round ended under
	them), and a second kill arriving before the first killcam finished.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CameraController = require(script.Parent.CameraController)
local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local Match = require(ReplicatedStorage.Shared.Match)
local MatchController = require(script.Parent.MatchController)
local Net = require(ReplicatedStorage.Shared.Net)
local TitleStyle = require(script.Parent.Parent.UI.TitleStyle)
local UIController = require(script.Parent.UIController)

local log = Log.new("KillcamController")

local player = Players.LocalPlayer

local SCREEN_NAME = "Killcam"
local SCREENS_FOLDER = "Screens"

-- Bounded: a place where the screen was never authored costs one warning
-- instead of a Start() that never returns.
local SCREEN_TIMEOUT = 10

-- Where the lens sits relative to the killer: back along their facing, and up.
-- Far enough back that a sprinting, jumping character never reaches it.
local FOLLOW_DISTANCE = 9
local FOLLOW_HEIGHT = 3.5

-- The camera aims here, above the root part, so the frame holds a head and
-- shoulders rather than a waistline.
local FOCUS_HEIGHT = 1.5

--[[
	Hard floor on the distance from the focus point, applied AFTER the
	smoothing. The opening move interpolates from wherever the victim was
	looking when they died -- which is frequently the killer's face, from a
	metre away -- and a straight line from there to the shoulder passes through
	the head. This is what turns that into an arc around it.
]]
local MIN_FOCUS_DISTANCE = 5

--[[
	Follow rate, per second, applied as 1 - exp(-rate * dt) rather than as a
	flat per-frame alpha. A flat alpha is a different camera on every machine:
	the same 0.1 follows twice as fast at 120fps as at 60.
]]
local FOLLOW_STIFFNESS = 6

local RENDER_BIND = "KillcamCamera"

--[[
	Upper bound on one killcam. respawnAt is server-authored and always lands
	inside Config.Killcam.Duration, so this is not about distrust -- it is that
	the failure mode of a deadline that never arrives is not a stuck countdown,
	it is a camera override held for the rest of the session. The slack is for
	clock skew between GetServerTimeNow() calls, and nothing more.
]]
local MAX_KILLCAM_SECONDS = Config.Killcam.Duration + 2

--[[
	The authored labels, resolved once per PlayerGui population. Every field is
	optional on purpose: a renamed label should cost the line it drives, not the
	camera and the countdown, which are what actually stop a dead player
	staring at their own corpse.
]]
type Card = {
	banner: TextLabel?,
	avatar: ImageLabel?,
	name: TextLabel?,
	level: TextLabel?,
	kills: TextLabel?,
	respawn: TextLabel?,
	-- The killer's equipped title (TitleStyle), under their name.
	title: TextLabel?,
}

type KilledPacket = {
	killerUserId: number,
	killerName: string,
	killerLevel: number,
	killerKills: number,
	killerTitle: string,
	respawnAt: number,
}

--[[
	One run of the killcam. Everything that has to be undone lives in here, so
	"did I clean all of it up?" is answered by reading one type rather than by
	auditing a dozen module-level variables.
]]
type Session = {
	-- Compared by late callbacks (the thumbnail fetch, the expiry timer) before
	-- they touch anything: by the time they land, this killcam may be over and
	-- a different one running.
	token: number,
	killerUserId: number,
	respawnAt: number,
	camera: Camera,
	card: Card,
	pose: CFrame,
	-- Last whole second written to RespawnLabel. Seeded from the deadline in
	-- begin(), which writes that first label itself, so the render step only
	-- touches Text when the second actually rolls over.
	shownSeconds: number,
	release: (() -> ())?,
	expiry: thread?,
	connections: { RBXScriptConnection },
	renderBound: boolean,
}

local card: Card? = nil
local session: Session? = nil
local tokenCounter = 0

-- Set once Start() has had its chance to resolve the screen. Until then a
-- `killed` packet parks in `pending` rather than being dropped.
local started = false
local pending: KilledPacket? = nil

local warned: { [string]: boolean } = {}

local KillcamController = {}

--[[
	PlayerGui is wiped and re-cloned on every respawn (UIController.luau
	documents that churn at length), so the card is re-resolved often. A path
	that was missing the first time is missing every time, and one warning per
	respawn for the rest of the session is how a real one gets lost.
]]
local function warnOnce(message: string)
	if warned[message] then
		return
	end
	warned[message] = true
	log.warn(message)
end

local function setText(label: TextLabel?, text: string)
	if label ~= nil then
		label.Text = text
	end
end

local function findPath(root: Instance, path: string): Instance?
	local current: Instance = root
	for segment in string.gmatch(path, "[^%.]+") do
		local child = current:FindFirstChild(segment)
		if child == nil then
			return nil
		end
		current = child
	end
	return current
end

local function findLabel(root: Instance, path: string): TextLabel?
	local instance = findPath(root, path)
	if instance == nil then
		warnOnce(`{SCREEN_NAME}.Root.{path} is missing -- that line of the kill card stays as authored`)
		return nil
	end
	if not instance:IsA("TextLabel") then
		warnOnce(`{SCREEN_NAME}.Root.{path} is a {instance.ClassName}, not a TextLabel`)
		return nil
	end
	return instance
end

local function findImage(root: Instance, path: string): ImageLabel?
	local instance = findPath(root, path)
	if instance == nil then
		warnOnce(`{SCREEN_NAME}.Root.{path} is missing -- the kill card will show no picture`)
		return nil
	end
	if not instance:IsA("ImageLabel") then
		warnOnce(`{SCREEN_NAME}.Root.{path} is a {instance.ClassName}, not an ImageLabel`)
		return nil
	end
	return instance
end

local function resolveCard(screens: Instance): Card?
	local screen = screens:FindFirstChild(SCREEN_NAME)
	if screen == nil then
		warnOnce(`no {SCREENS_FOLDER}.{SCREEN_NAME} authored -- no kill card will be drawn`)
		return nil
	end

	local root = screen:FindFirstChild("Root")
	if root == nil then
		warnOnce(`{SCREEN_NAME} has no Root -- every screen's single root is named Root`)
		return nil
	end

	return {
		banner = findLabel(root, "TopBar.BannerLabel"),
		avatar = findImage(root, "Card.AvatarImage"),
		name = findLabel(root, "Card.NameLabel"),
		level = findLabel(root, "Card.LevelLabel"),
		kills = findLabel(root, "Card.KillsLabel"),
		respawn = findLabel(root, "RespawnLabel"),
		title = findLabel(root, "Card.TitleLabel"),
	}
end

--[[
	Seconds left on the respawn deadline. Absolute server time minus our own
	GetServerTimeNow(), the same arithmetic the round timer uses, so the
	countdown cannot drift away from the respawn the server actually scheduled.

	NaN is rejected by identity BEFORE the clamp, never after: both of clamp's
	comparisons are false for NaN, so it passes straight through
	(quality-gate.md trap #8) -- and a NaN here is the one input that would hold
	the camera override forever.
]]
local function remainingSeconds(respawnAt: number): number
	local remaining = respawnAt - workspace:GetServerTimeNow()
	if remaining ~= remaining then
		return 0
	end
	return math.clamp(remaining, 0, MAX_KILLCAM_SECONDS)
end

local function formatRespawn(seconds: number): string
	return if seconds > 0 then `RESPAWNING IN {seconds}` else "RESPAWNING"
end

local function killerRootPart(userId: number): BasePart?
	local killer = Players:GetPlayerByUserId(userId)
	if killer == nil then
		return nil
	end
	local character = killer.Character
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if root == nil or not root:IsA("BasePart") then
		return nil
	end
	return root
end

local function onRenderStep(deltaTime: number)
	local current = session
	if current == nil then
		return
	end

	local root = killerRootPart(current.killerUserId)
	if root ~= nil then
		local focus = root.Position + Vector3.new(0, FOCUS_HEIGHT, 0)

		--[[
			Facing is flattened to the XZ plane rather than taken in root space.
			A killer who is mid-jump, on a ramp or being shoved has a pitched
			root, and `root.CFrame * offset` would roll the entire killcam with
			them -- a camera that tilts because the subject tilted reads as a
			bug, not as drama.
		]]
		local look = root.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		-- Looking straight up or down leaves nothing to flatten; park behind
		-- the world axis rather than normalising a zero vector into NaN.
		local behind = if flat.Magnitude > 1e-3 then -flat.Unit else Vector3.new(0, 0, 1)

		local goal = CFrame.lookAt(focus + behind * FOLLOW_DISTANCE + Vector3.new(0, FOLLOW_HEIGHT, 0), focus)
		current.pose = current.pose:Lerp(goal, 1 - math.exp(-FOLLOW_STIFFNESS * deltaTime))

		local offset = current.pose.Position - focus
		local distance = offset.Magnitude
		if distance < MIN_FOCUS_DISTANCE then
			local direction = if distance > 1e-3 then offset.Unit else behind
			current.pose = CFrame.lookAt(focus + direction * MIN_FOCUS_DISTANCE, focus)
		end
	end
	--[[
		No root means the killer has left the server, or their character has not
		replicated to us yet. The pose is simply held: the last framing of where
		they were beats a camera snapping to the world origin, the card is
		already filled from the packet, and the countdown below still ends this
		on time.
	]]

	current.camera.CFrame = current.pose

	-- Written only when the whole second changes. This is a clock, not an
	-- animation, and assigning Text re-lays the label out every time.
	local seconds = math.ceil(remainingSeconds(current.respawnAt))
	if seconds ~= current.shownSeconds then
		current.shownSeconds = seconds
		setText(current.card.respawn, formatRespawn(seconds))
	end
end

local function teardown(current: Session)
	if current.renderBound then
		current.renderBound = false
		RunService:UnbindFromRenderStep(RENDER_BIND)
	end

	for _, connection in current.connections do
		connection:Disconnect()
	end
	table.clear(current.connections)

	--[[
		Read and cleared before the cancel. The expiry thread nils this as its
		own first statement, so a finish() reached FROM that thread finds
		nothing to cancel rather than killing the coroutine it is running on --
		the same ordering SpawnService uses for its respawn threads.
	]]
	local expiry = current.expiry
	current.expiry = nil
	if expiry ~= nil then
		task.cancel(expiry)
	end

	-- Custom, not "whatever it was": outside a killcam the only legitimate
	-- owner of this camera is the default camera script, and the release below
	-- is what puts CameraController's first-person lock back on top of it.
	current.camera.CameraType = Enum.CameraType.Custom

	UIController.close(SCREEN_NAME)
end

local function finish()
	local current = session
	if current == nil then
		return
	end

	-- Cleared first, before any work. finish() is reachable from five places
	-- and two of them can land in the same frame; clearing up front is what
	-- makes the second call a no-op instead of a double release.
	session = nil

	--[[
		pcall then release, in that order, because Luau has no finally. Teardown
		touches instances that may already be destroyed (the camera on a
		CurrentCamera swap, the screen on a PlayerGui reset), and an error there
		must not be the thing that strands an override nothing else will ever
		release.
	]]
	local ok: boolean, err: string? = pcall(teardown, current)

	local release = current.release
	current.release = nil
	if release ~= nil then
		release()
	end

	if not ok then
		log.warn(`teardown errored; the camera override was released anyway: {err}`)
	end
end

--[[
	Takes the ImageLabel rather than reading it off the card, so the nil check
	lives at the one call site and the thread below closes over a value the
	typechecker already knows is there.
]]
local function loadAvatar(current: Session, image: ImageLabel)
	local userId = current.killerUserId

	-- Cleared before the request goes out: the ImageLabel outlives a killcam,
	-- and leaving the previous killer's face up while this one is in flight is
	-- the single failure mode here that actively misinforms.
	image.Image = ""

	task.spawn(function()
		--[[
			pcall because this is a web call: it yields, and it throws outright
			on a moderated or unavailable thumbnail. A card with no picture is
			the right answer -- the name, level and kill count are what the
			player actually needs, and none of them depend on this succeeding.
		]]
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
		end)
		if not ok then
			log.warn(`thumbnail for {userId} failed: {content}`)
			return
		end

		-- The reply outlived the killcam that asked for it: respawned, round
		-- over, or killed again by somebody else. Writing now would paint the
		-- wrong face onto the card currently on screen.
		local running = session
		if running == nil or running.token ~= current.token then
			return
		end
		image.Image = content
	end)
end

local function begin(data: KilledPacket)
	local resolved = card
	if resolved == nil then
		-- resolveCard already warned once. A warning per death after that is
		-- noise on a screen nobody authored.
		return
	end

	--[[
		A stale packet: one that parked in `pending` while Start() waited for
		PlayerGui, or a clock far enough out that the deadline has already
		passed. Taking the camera to hand it straight back is a flicker with no
		information in it.
	]]
	local secondsLeft = remainingSeconds(data.respawnAt)
	if secondsLeft <= 0 then
		return
	end

	--[[
		Resolved BEFORE finish() below, not after. No camera means no killcam,
		and finishing first would end a killcam that was working in order to
		then bail out of starting its replacement -- the one arrangement in
		which this guard costs the player something instead of saving them.
	]]
	local camera = workspace.CurrentCamera
	if camera == nil then
		log.warn("no CurrentCamera -- skipping the killcam rather than taking an override nothing can drive")
		return
	end

	-- A second kill before the first killcam ended. The server does not do this
	-- today, but the override is reference counted and a take that is never
	-- released is permanent, so exactly one is kept outstanding.
	finish()

	tokenCounter += 1
	local current: Session = {
		token = tokenCounter,
		killerUserId = data.killerUserId,
		respawnAt = data.respawnAt,
		camera = camera,
		card = resolved,
		-- Starts where the player is actually looking, so the opening move is a
		-- sweep onto the killer's shoulder rather than a cut.
		pose = camera.CFrame,
		shownSeconds = math.ceil(secondsLeft),
		release = nil,
		expiry = nil,
		connections = {},
		renderBound = false,
	}
	session = current

	-- Taken before the camera is touched: until this returns, CameraController
	-- is still forcing LockFirstPerson, and a Scriptable camera under that lock
	-- fights it for as long as the gap lasts.
	current.release = CameraController.override("Killcam")

	--[[
		Armed in the same breath as the take, before any of the work below it.
		Every other exit needs something else to still be working -- a
		connection to have been made, a phase to change, a screen to exist --
		and all of those are set up further down, past calls that can throw
		(UIController.open runs the transition system; BindToRenderStep rejects
		a name already bound). A throw between the take and the end of begin()
		would otherwise leave an override held by a session nothing is driving,
		which is the one failure this file exists to make impossible. This
		timer depends on nothing, so it is armed first and is what is still
		standing if anything below it falls over.

		Guarded by token, not by "is anything running": a killcam that ended
		early and was replaced by a newer one must not be ended by the old
		one's timer.
	]]
	current.expiry = task.delay(secondsLeft, function()
		local running = session
		if running == nil or running.token ~= current.token then
			return
		end
		-- Nil'd before finish() so teardown does not cancel this very thread.
		running.expiry = nil
		finish()
	end)

	camera.CameraType = Enum.CameraType.Scriptable

	setText(resolved.banner, `ELIMINATED BY {data.killerName}`)
	setText(resolved.name, data.killerName)
	setText(resolved.level, `LEVEL {data.killerLevel}`)
	setText(resolved.kills, if data.killerKills == 1 then "1 KILL" else `{data.killerKills} KILLS`)
	setText(resolved.respawn, formatRespawn(current.shownSeconds))

	-- An empty line when the killer has no title equipped; TitleStyle clears
	-- the previous killer's animation either way.
	local titleLabel = resolved.title
	if titleLabel ~= nil then
		TitleStyle.apply(titleLabel, data.killerTitle)
	end

	local avatar = resolved.avatar
	if avatar ~= nil then
		loadAvatar(current, avatar)
	end

	UIController.open(SCREEN_NAME)

	-- The character coming back is the moment the player is owed their own eyes
	-- again. It normally lands within a frame of the expiry armed above;
	-- whichever wins, finish() is idempotent.
	table.insert(
		current.connections,
		player.CharacterAdded:Connect(function()
			finish()
		end)
	)

	-- Camera priority, so this writes in the slot the default camera script
	-- would have used rather than a frame behind it.
	RunService:BindToRenderStep(RENDER_BIND, Enum.RenderPriority.Camera.Value, onRenderStep)
	current.renderBound = true
end

function KillcamController.Init()
	--[[
		Registered here, not in Start(): a packet fired at a client with no
		listener is dropped, not queued (DevConsoleController.luau says the same
		of devAccess). `killed` cannot realistically beat Start() -- you have to
		be alive in a round first -- but the screen it drives can only be found
		in Start(), so the two are held apart by an explicit pending slot rather
		than by that assumption staying true.
	]]
	Net.killed.listen(function(data)
		if not started then
			pending = data
			return
		end
		begin(data)
	end)
end

function KillcamController.Start()
	-- Everything that yields lives here: Init() must be synchronous or the
	-- Loader hard-errors, and PlayerGui is populated by replication from
	-- StarterGui well after every Init() has run.
	local playerGui = player:WaitForChild("PlayerGui")
	local screens = playerGui:WaitForChild(SCREENS_FOLDER, SCREEN_TIMEOUT)

	started = true
	local queued = pending
	pending = nil

	if screens == nil then
		log.warn(`no PlayerGui.{SCREENS_FOLDER} after {SCREEN_TIMEOUT}s -- the killcam will not be drawn`)
		return
	end

	card = resolveCard(screens)

	--[[
		StarterGui.ResetPlayerGuiOnSpawn re-clones the whole of PlayerGui on
		every respawn, so the labels resolved above are destroyed instances the
		moment this player first comes back -- and a killcam is precisely what
		runs in the seconds before a respawn. Re-resolving against the
		replacement folder is the same churn UIController.luau absorbs by
		addressing screens by name.
	]]
	playerGui.ChildAdded:Connect(function(child: Instance)
		if child.Name ~= SCREENS_FOLDER then
			return
		end
		--[[
			Only the folder UIController adopted. At the first character spawn
			the engine copies StarterGui into PlayerGui regardless, so a second
			Screens folder appears for a moment before UIController destroys it.
			Re-resolving the card from that one would leave this controller
			pointing into a destroyed tree, silently, for the session
			(UIController.getScreensFolder).
		]]
		if child ~= UIController.getScreensFolder() then
			return
		end
		card = resolveCard(child)
	end)

	--[[
		The phase leaving Killcam covers the two ends the server owns: the
		respawn it scheduled, and the player walking back to the menu mid-cam
		(BackButton, or being dropped from the round). Either way the killcam is
		over and the override has to come back.
	]]
	MatchController.onPhaseChanged(function(phase: Match.PlayerPhase)
		if phase ~= "Killcam" then
			finish()
		end
	end)

	--[[
		And the end the server does NOT express as a phase: a round that ends
		while this player is dead leaves them in Killcam through RoundResults
		(RoundService never touches phases there), so without this the camera
		would stay locked on a corpse behind the results panel.
	]]
	MatchController.onStateChanged(function(state: Match.MatchState)
		if state ~= "RoundActive" then
			finish()
		end
	end)

	if queued ~= nil then
		begin(queued)
	end
end

return KillcamController
