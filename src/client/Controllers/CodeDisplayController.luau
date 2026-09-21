--!strict
--[[
	The four digits above a head.

	THE CODES ARRIVE IN A PACKET, AND THE PACKET IS THE WHOLE TRUTH.

	Net.codeVisibility carries the codes this client is allowed to see right
	now -- only the players close enough to read (CodeService, "make sure a
	client is only ever GIVEN the codes it could already read"). It is the
	COMPLETE set every time, never a delta, and that is what makes this file
	short: a userId missing from the list means "stop drawing that player", and
	that one rule already covers walking out of range, dying, being released at
	round end and leaving the server. There is no "hide it now" branch in here
	to get out of step with the round.

	So the model is two halves crossed against each other: userId -> code from
	the packet, and userId -> character from Workspace. Either half can arrive
	first and neither is waited on.

	EVERYTHING ABOUT A SPAWN ARRIVES LATE, AND SEPARATELY. The model, its Head,
	its accessories and the packet naming it each replicate on their own
	schedule, and Player.Character is a property write that lands after the
	model does -- which is why subjectOf has a name fallback and why the
	headband is looked for again on DescendantAdded. Resolving any of it once,
	when the model shows up, draws nothing at all on a busy server and works
	perfectly in an empty Studio session, which is the worst pair of outcomes
	on offer.

	THE CODE IS PRINTED ON THE FRONT OF THE BAND, AND ONLY THE FRONT. The band
	ships a `Sign` plate whose Top face points the way the character looks, and
	one SurfaceGui is drawn on that face. Turning your back on someone so they
	cannot read your code is the mechanic, not a limitation of the rendering --
	a player who keeps a wall or their own shoulders between themselves and a
	reader is playing the game correctly, and a second face on the back of the
	plate would delete that entirely.

	WHAT THAT COSTS, AND THE ONE KNOB IT COSTS IT ON. A SurfaceGui's 2D basis
	is derived from the PART'S axes, so which way up the digits land is a
	property of how the Sign is rotated inside the model -- see
	SIGN_TEXT_ROTATION, which is the single line that has to move if the artist
	re-rotates that part. It is one constant precisely because it is a fact
	about the art, not about this file.

	WHY AlwaysOnTop STAYS FALSE. The range bound is the only thing standing
	between a client and every code in the server, and a surface that renders
	through geometry hands back the half of it that a wall was hiding. The
	skill being tested is reading a number off a body you can actually see.

	Creating these GUIs here is the sanctioned exception to "Studio owns the
	GUIs": a body is created at spawn and destroyed at death, so there is
	nothing in StarterGui for a per-character label to be authored onto.
	Screens are still found, never built.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local Match = require(ReplicatedStorage.Shared.Match)
local MatchController = require(script.Parent.MatchController)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("CodeDisplayController")

local localPlayer = Players.LocalPlayer

-- The accessory as it exists ON a character: CodeService clones
-- ServerStorage.Assets.Headband and renames it while attaching, so this name
-- is the only one a client ever sees.
local HEADBAND_NAME = "KillCodeHeadband"
-- The plate inside it. No Handle fallback: the Handle is the band across the
-- skull, and a number printed along the side of someone's head reads worse
-- than the billboard we fall back to instead.
local SIGN_NAME = "Sign"

-- Clear of the hair. The fallback billboard only -- the Sign is already where
-- the artist put it and nothing here moves it.
local HEAD_OFFSET = Vector3.new(0, 2.6, 0)

--[[
	The Sign is authored rotated, and a SurfaceGui's 2D basis comes from the
	part's axes, so the text lands rotated with it.

	MEASURED, 2026-09-21. The Sign was placed on a head frame the same way the
	HatAttachment places it, with a label at 0 and one at 180, and the result
	was captured from in front. 0 reads upright. 180 is upside down, which is
	what players were seeing while this was set to 180 on an untested
	hypothesis. Reason about the axes if you like, but confirm any change the
	same way: look at the capture.

	If the model's rotation changes, this is the one knob that has to change
	with it.
]]
local SIGN_TEXT_ROTATION = 0

--[[
	The Sign's Top face reads 1.80 studs wide by 0.80 tall. At this density
	that is a 180x80 canvas -- enough that TextScaled has real pixels to work
	with, and small enough that four digits never cost a texture worth
	discussing.
]]
local SIGN_PIXELS_PER_STUD = 100

type Relationship = "Self" | "Teammate" | "Enemy" | "Unknown"

type Style = {
	-- The fallback billboard only. The Sign is a size the artist authored, and
	-- the SurfaceGui fills whatever face it is given.
	Size: UDim2,
	-- A hard cutoff, not a falloff -- neither GUI class has a distance fade to
	-- ask for. Past it a number is unreadable anyway, and thirty unreadable
	-- numbers across a map are what stands between a player and the one they
	-- can actually read.
	MaxDistance: number,
	CodeColor: Color3,
	CodeTransparency: number,
	StrokeTransparency: number,
	-- "" means no tag line, and the number then takes the whole face so it
	-- still reads as centred.
	Tag: string,
	TagColor: Color3,
}

--[[
	The whole of design brief 26, as data.

	An enemy is white on a hard outline at the largest size: the number IS the
	interaction, and anything that makes it harder to read is a bug. A teammate
	is small, dim and desaturated and says TEAMMATE in words, because a
	red-on-white number above a friend is an invitation to waste a submission
	on someone the server will refuse anyway. The team's own colour is
	deliberately NOT used for that -- a saturated hue is what makes a number
	look like a target, which is the exact reading we are trying to prevent.

	Your own code is in the packet too (Net.luau, codeVisibility) and is marked
	YOU, so nobody spends a round typing their own number at themselves.
]]
local STYLES: { [string]: Style } = {
	Enemy = {
		Size = UDim2.fromOffset(190, 72),
		MaxDistance = 160,
		CodeColor = Color3.fromRGB(255, 255, 255),
		CodeTransparency = 0,
		StrokeTransparency = 0,
		Tag = "",
		TagColor = Color3.fromRGB(255, 255, 255),
	},
	Teammate = {
		Size = UDim2.fromOffset(128, 56),
		MaxDistance = 90,
		CodeColor = Color3.fromRGB(146, 156, 170),
		CodeTransparency = 0.35,
		StrokeTransparency = 0.5,
		Tag = "TEAMMATE",
		TagColor = Color3.fromRGB(146, 156, 170),
	},
	Self = {
		Size = UDim2.fromOffset(96, 42),
		MaxDistance = 40,
		CodeColor = Color3.fromRGB(205, 212, 224),
		CodeTransparency = 0.4,
		StrokeTransparency = 0.5,
		Tag = "YOU",
		TagColor = Color3.fromRGB(205, 212, 224),
	},
	--[[
		The round replica has not told us who this is yet. Drawn like a
		teammate minus the word: briefly dimming an enemy costs a moment of
		hesitation, briefly labelling a teammate as a target costs a
		submission and contradicts the rule above.
	]]
	Unknown = {
		Size = UDim2.fromOffset(128, 56),
		MaxDistance = 90,
		CodeColor = Color3.fromRGB(176, 182, 194),
		CodeTransparency = 0.4,
		StrokeTransparency = 0.5,
		Tag = "",
		TagColor = Color3.fromRGB(176, 182, 194),
	},
}

local OUTLINE_COLOR = Color3.fromRGB(10, 10, 14)

type Display = {
	-- Held as the common base so cleanup and the destroyed-under-us check need
	-- no branch; the two class-specific fields below carry what does.
	gui: LayerCollector,
	--[[
		Exactly one of these is non-nil. Kept as separate typed fields rather
		than one union, because the properties that differ (Size, and which
		class owns MaxDistance) are read under strict typing and a union would
		need narrowing at every use.
	]]
	surface: SurfaceGui?,
	billboard: BillboardGui?,
	codeLabel: TextLabel,
	tagLabel: TextLabel,
	stroke: UIStroke,
	-- The part it is drawn on: the band's Sign, or the Head.
	host: BasePart,
	-- False while we are on the Head because the band had not replicated yet;
	-- the one thing that still makes us watch for parts.
	onSign: boolean,
}

type Entry = {
	character: Model,
	-- Lives and dies with the character. Never two for one character: every
	-- path that would make a second one goes through ensureDisplay.
	display: Display?,
	subject: Player?,
	-- The relationship the current visuals were built for, so a Players write
	-- (one per kill, per death, per team change) does not rewrite every
	-- property of every label in the server.
	styled: Relationship?,
	partConnection: RBXScriptConnection?,
}

--[[
	userId -> code, replaced wholesale by every codeVisibility packet. A userId
	that is absent is a player this client may not see, for whatever reason;
	the client is never told which reason and does not need to be.
]]
local codes: { [number]: string } = {}

--[[
	Keyed by Instance rather than Model so Workspace.ChildRemoved can look an
	entry up without first proving the thing that left was a Model. This table
	IS the leak: Destroy on a character takes its gui with it, but the entry
	and its connection survive it, and thirty of those per round for a whole
	session is the exact growth the cleanup rule exists to stop.
]]
local watched: { [Instance]: Entry } = {}

local CodeDisplayController = {}

--[[
	The surface the code is printed on: the band's Sign when the band is here,
	the Head otherwise, and nil while the character has neither.

	The Handle is deliberately not a fallback -- see SIGN_NAME.
]]
local function resolveHost(character: Model): (BasePart?, boolean)
	for _, child in character:GetChildren() do
		if not child:IsA("Accessory") or child.Name ~= HEADBAND_NAME then
			continue
		end

		local sign = child:FindFirstChild(SIGN_NAME, true)
		if sign ~= nil and sign:IsA("BasePart") then
			return sign, true
		end
	end

	local head = character:FindFirstChild("Head")
	if head ~= nil and head:IsA("BasePart") then
		return head, false
	end
	return nil, false
end

--[[
	The Player behind a character, or nil while we cannot tell. This is what
	turns a userId in the packet into a body on screen, so a character nobody
	can name draws nothing at all.

	Player.Character is a property write that replicates separately from the
	model itself, so GetPlayerFromCharacter is reliably nil for the first
	frames of a spawn -- the frames in which the first packet naming that
	player usually lands. The name fallback covers that window; the result is
	cached only once it is real, so a failed resolution is retried rather than
	frozen in.
]]
local function subjectOf(entry: Entry): Player?
	local cached = entry.subject
	if cached ~= nil and cached.Parent ~= nil then
		return cached
	end

	local subject = Players:GetPlayerFromCharacter(entry.character)
	if subject == nil then
		local named = Players:FindFirstChild(entry.character.Name)
		if named ~= nil and named:IsA("Player") then
			subject = named
		end
	end

	entry.subject = subject
	return subject
end

--[[
	The team a player holds in the round replica, or nil if the replica has not
	reached us or has no row for them yet. Read through MatchController because
	nothing outside it touches the replica.
]]
local function teamOf(userId: number): string?
	local round = MatchController.getRound()
	if round == nil then
		return nil
	end

	local players = round.Players
	if type(players) ~= "table" then
		return nil
	end

	local row = players[Match.playerKey(userId)]
	if type(row) ~= "table" then
		return nil
	end

	local team = row.Team
	return if type(team) == "string" and team ~= "" then team else nil
end

local function relationshipTo(entry: Entry): Relationship
	local subject = subjectOf(entry)
	if subject == localPlayer then
		return "Self"
	end

	-- Free For All has no teams to be on the wrong side of, so there is
	-- nothing to wait for the replica to tell us.
	if not MatchController.usesTeams() then
		return "Enemy"
	end

	local selfRow = MatchController.getSelfEntry()
	local myTeam = if selfRow ~= nil then selfRow.Team else nil
	local theirTeam = if subject ~= nil then teamOf(subject.UserId) else nil
	if type(myTeam) ~= "string" or myTeam == "" or theirTeam == nil then
		return "Unknown"
	end

	return if myTeam == theirTeam then "Teammate" else "Enemy"
end

local function applyStyle(entry: Entry)
	local display = entry.display
	if display == nil then
		return
	end

	--[[
		Annotated, and it has to be: an unannotated local taking a call's
		result loses the singleton union under refinement, so the `styled`
		write below is seen as a plain `string` and fails strict analysis
		against Relationship. The annotation costs nothing and is the whole fix.
	]]
	local relationship: Relationship = relationshipTo(entry)
	if entry.styled == relationship then
		return
	end
	--[[
		Unknown is never recorded as applied, so the next Players write
		re-resolves it instead of leaving a teammate greyed out for the round.
		One is guaranteed: a player is only in our visible set because the
		server just spawned them into the round, which writes their row.
	]]
	if relationship == "Unknown" then
		entry.styled = nil
	else
		entry.styled = relationship
	end

	local style = STYLES[relationship]

	local billboard = display.billboard
	if billboard ~= nil then
		billboard.Size = style.Size
		billboard.MaxDistance = style.MaxDistance
	end

	local surface = display.surface
	if surface ~= nil then
		surface.MaxDistance = style.MaxDistance
	end

	display.codeLabel.TextColor3 = style.CodeColor
	display.codeLabel.TextTransparency = style.CodeTransparency
	display.codeLabel.Size = if style.Tag == "" then UDim2.fromScale(1, 1) else UDim2.fromScale(1, 0.7)
	display.stroke.Transparency = style.StrokeTransparency
	display.tagLabel.Text = style.Tag
	display.tagLabel.Visible = style.Tag ~= ""
	display.tagLabel.TextColor3 = style.TagColor
	display.tagLabel.TextTransparency = style.CodeTransparency
end

--[[
	The number and its tag line, filling whatever container they are given: the
	Sign's face, or the whole billboard.

	`rotation` is the art's problem, not the layout's. The billboard always
	passes 0, and the Sign passes SIGN_TEXT_ROTATION, which is also 0 for the
	current model but is kept separate so a re-rotated Sign has its own knob.

	The outline is not a backing frame: a panel behind the number occludes the
	body you are aiming at, and this has to stay legible against a white skybox
	and a black interior with no per-map tuning.
]]
local function createLabels(parent: LayerCollector, rotation: number): (TextLabel, TextLabel, UIStroke)
	local codeLabel = Instance.new("TextLabel")
	codeLabel.Name = "CodeLabel"
	codeLabel.BackgroundTransparency = 1
	codeLabel.Size = UDim2.fromScale(1, 0.7)
	codeLabel.Font = Enum.Font.GothamBlack
	codeLabel.TextScaled = true
	codeLabel.Rotation = rotation
	codeLabel.Text = ""
	codeLabel.Parent = parent

	local stroke = Instance.new("UIStroke")
	stroke.Name = "CodeStroke"
	stroke.Thickness = 3
	stroke.Color = OUTLINE_COLOR
	stroke.Parent = codeLabel

	local tagLabel = Instance.new("TextLabel")
	tagLabel.Name = "TagLabel"
	tagLabel.BackgroundTransparency = 1
	tagLabel.Position = UDim2.fromScale(0, 0.7)
	tagLabel.Size = UDim2.fromScale(1, 0.3)
	tagLabel.Font = Enum.Font.GothamMedium
	tagLabel.TextScaled = true
	tagLabel.Rotation = rotation
	tagLabel.Text = ""
	tagLabel.Visible = false
	tagLabel.Parent = parent

	local tagStroke = Instance.new("UIStroke")
	tagStroke.Name = "TagStroke"
	tagStroke.Thickness = 2
	tagStroke.Color = OUTLINE_COLOR
	tagStroke.Parent = tagLabel

	return codeLabel, tagLabel, stroke
end

--[[
	The code printed on the front of the band, which is the whole mechanic --
	see the header for why there is no second face on the back.
]]
local function createSignDisplay(entry: Entry, sign: BasePart): Display
	local gui = Instance.new("SurfaceGui")
	gui.Name = "KillCodeSignFront"
	gui.Face = Enum.NormalId.Top
	gui.Adornee = sign
	-- See the header: a code readable through a wall is a different game.
	gui.AlwaysOnTop = false
	-- A code in shadow is still the thing the player has to read.
	gui.LightInfluence = 0
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = SIGN_PIXELS_PER_STUD
	gui.Parent = sign

	local codeLabel, tagLabel, stroke = createLabels(gui, SIGN_TEXT_ROTATION)

	local display: Display = {
		gui = gui,
		surface = gui,
		billboard = nil,
		codeLabel = codeLabel,
		tagLabel = tagLabel,
		stroke = stroke,
		host = sign,
		onSign = true,
	}
	entry.display = display
	-- Nothing has been styled onto a brand new gui, whatever the last one wore.
	entry.styled = nil
	return display
end

--[[
	The fallback, for a character with no band on it: the asset is missing from
	this place, or the accessory simply has not replicated yet. A body wearing
	no readable number cannot be killed at all, so this path stays.

	No rotation: a billboard faces the viewer and has no part-derived basis to
	come out wrong.
]]
local function createBillboardDisplay(entry: Entry, head: BasePart): Display
	local gui = Instance.new("BillboardGui")
	gui.Name = "KillCodeBillboard"
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.StudsOffset = HEAD_OFFSET
	gui.Adornee = head
	gui.Parent = head

	local codeLabel, tagLabel, stroke = createLabels(gui, 0)

	local display: Display = {
		gui = gui,
		surface = nil,
		billboard = gui,
		codeLabel = codeLabel,
		tagLabel = tagLabel,
		stroke = stroke,
		host = head,
		onSign = false,
	}
	entry.display = display
	entry.styled = nil
	return display
end

local function destroyDisplay(entry: Entry)
	local display = entry.display
	if display == nil then
		return
	end

	entry.display = nil
	entry.styled = nil
	display.gui:Destroy()
end

-- Forward declared: the part watch below is armed by refresh and calls back
-- into it, and refresh is what knows whether the watch is still wanted.
local refresh: (entry: Entry) -> ()

--[[
	Stops the per-descendant watch once there is nothing left for it to find.
	A character gains descendants for its whole life (tools, accessories), so
	a callback that can no longer act on anything should not stay bound to that
	traffic.
]]
local function stopWatchingParts(entry: Entry)
	local connection = entry.partConnection
	if connection == nil then
		return
	end

	entry.partConnection = nil
	connection:Disconnect()
end

--[[
	Starts it again, and it IS again: a band can arrive more than once on one
	body. CodeService.release strips the band and .assign attaches a fresh one,
	so a watch that could only ever be armed at watch() time would be gone by
	the second assignment and leave that code stranded on the Head for the rest
	of the life. Armed only while something is still missing, which is also
	what keeps it off every non-character Model in Workspace -- the loaded map
	never gets one, because the map never appears in a visibility packet.
]]
local function startWatchingParts(entry: Entry)
	if entry.partConnection ~= nil then
		return
	end

	entry.partConnection = entry.character.DescendantAdded:Connect(function()
		-- Only the Head and the band's Sign change anything here, and
		-- resolveHost is the only thing that knows which is which.
		refresh(entry)
	end)
end

--[[
	The display, on the best surface available right now, or nil while the
	character has nothing to draw on at all.
]]
local function ensureDisplay(entry: Entry): Display?
	local display = entry.display
	--[[
		The common path, and it has to be the cheap one: the server pushes a
		fresh visible set every Config.Code.VisibilityInterval and this runs
		once per body in it. A display already on the Sign has nothing better
		left to find, so nothing walks the character's children again.
	]]
	if display ~= nil and display.onSign and display.host.Parent ~= nil then
		return display
	end

	local part, onSign = resolveHost(entry.character)
	if part == nil then
		-- Not even a Head yet, so there is nothing to mount on and nothing to
		-- do but wait for one to replicate in.
		startWatchingParts(entry)
		return nil
	end

	--[[
		Rebuilt rather than moved when the surface changes, because the two
		paths are not the same GUI class: a SurfaceGui printed on the Sign, a
		BillboardGui floating over the Head. Still one display per character --
		the old one is destroyed in the same breath.

		The `Parent == nil` half is the band being stripped at release, which
		destroys the Sign under us: Parent is locked on a destroyed instance,
		so anything that tried to move a gui off it would throw inside a signal
		handler.
	]]
	if display ~= nil and (display.host ~= part or display.gui.Parent == nil) then
		destroyDisplay(entry)
		display = nil
	end

	if display == nil then
		display = if onSign then createSignDisplay(entry, part) else createBillboardDisplay(entry, part)
	end

	-- On the Sign there is nothing better left to find; on the Head the band
	-- may still be on its way.
	if onSign then
		stopWatchingParts(entry)
	else
		startWatchingParts(entry)
	end
	return display
end

function refresh(entry: Entry)
	local subject = subjectOf(entry)

	--[[
		NEVER DRAW YOUR OWN CODE.

		The plate hangs above and in front of the head, which in a first-person
		game is the middle of your own screen -- so a label on your own band sits
		over the crosshair for the entire round. Making the Sign part invisible
		does not fix it: LocalTransparencyModifier hides the PART, and a
		SurfaceGui is not a part, so the digits carried on merrily rendering in
		mid-air.

		Not drawn rather than hidden, because there is nothing you could use it
		for: your own code is the one number that can never be typed at anybody,
		and the server sends it only so this file can tell which band is yours.
	]]
	if subject == localPlayer then
		destroyDisplay(entry)
		stopWatchingParts(entry)
		return
	end

	local code = if subject ~= nil then codes[subject.UserId] else nil
	if code == nil then
		--[[
			Not in the visible set: out of range, dead, released at round end,
			gone from the server, or a model we cannot yet name. The absence is
			the instruction and the reason is never sent, which is exactly what
			collapses five cases into this one branch.
		]]
		destroyDisplay(entry)
		-- And nothing to look for either, until the next packet says otherwise.
		stopWatchingParts(entry)
		return
	end

	local display = ensureDisplay(entry)
	if display == nil then
		-- No Head yet. DescendantAdded brings us straight back.
		return
	end

	-- Assigned every time rather than only on creation: a respawn is a NEW
	-- code on the same body (CodeService.assign, previousCodes).
	display.codeLabel.Text = code
	applyStyle(entry)
end

local function refreshAll()
	for _, entry in watched do
		refresh(entry)
	end
end

local function unwatch(instance: Instance)
	local entry = watched[instance]
	if entry == nil then
		return
	end

	watched[instance] = nil
	stopWatchingParts(entry)

	-- Destroying the character already took the gui; this is for the paths
	-- that only reparent it, and it costs nothing when the gui is gone.
	destroyDisplay(entry)
end

--[[
	Every Model in Workspace is a candidate, and no Humanoid check filters
	them: a character model replicates before its Humanoid does, so the filter
	would reject exactly the characters it was written for. The cost of being
	wrong is one table entry on the loaded map's root model, which no packet
	will ever name; the expensive watch, DescendantAdded, is armed by refresh
	only once a code has actually appeared for that body.
]]
local function watch(instance: Instance)
	if not instance:IsA("Model") or watched[instance] ~= nil then
		return
	end

	local entry: Entry = {
		character = instance :: Model,
		display = nil,
		subject = nil,
		styled = nil,
		partConnection = nil,
	}
	watched[instance] = entry

	refresh(entry)
end

local function restyleAll()
	for _, entry in watched do
		applyStyle(entry)
	end
end

function CodeDisplayController.Init()
	--[[
		Registered here, not in Start(): a packet fired at a client with no
		listener is dropped, not queued (DataController.luau makes the same
		argument for Replica.OnNew). CodeService sweeps on a loop from its own
		Start, so the first visible set can land before this controller's Start
		has run -- and being missed once is not one dropped frame, it is every
		code on screen being absent until the set next CHANGES, because a sweep
		that finds an unchanged set sends nothing at all.

		Drawing nothing yet is fine: watched is empty until Start scans
		Workspace, and that scan refreshes every body against this table.
	]]
	Net.codeVisibility.listen(function(entries)
		--[[
			Replaced wholesale, never merged. The packet is the complete set,
			so a merge would keep drawing the code of the player who just
			walked behind a wall -- which is the one thing the range bound
			exists to prevent.
		]]
		table.clear(codes)
		for _, visible in entries do
			codes[visible.userId] = visible.code
		end

		refreshAll()
	end)

	--[[
		Dead, so every number goes now, before the server's empty set arrives.
		A player in the killcam is shown no codes at all (CodeService.
		sweepVisibility), and the killer has just been given a new one. Until
		the next sweep this client would otherwise keep drawing the killer's
		OLD number across the killcam shot: dead, but still a number on the
		face of the person who killed you. The server's empty set is what keeps
		it that way afterwards.
	]]
	Net.killed.listen(function()
		table.clear(codes)
		refreshAll()
	end)
end

function CodeDisplayController.Start()
	-- Scan first, then connect. Nothing between the two yields, so no
	-- character can arrive in the gap -- and a late joiner walks into a
	-- Workspace already full of bodies, which is the case a ChildAdded-only
	-- implementation misses entirely.
	for _, child in Workspace:GetChildren() do
		watch(child)
	end
	Workspace.ChildAdded:Connect(watch)
	Workspace.ChildRemoved:Connect(unwatch)

	--[[
		Restyle, never rebuild. Players covers a team being picked and a phase
		moving; ModeId covers the whole TDM/FFA fork, where every teammate in
		the server becomes an enemy at once. Both fire on subscribe, so the
		bodies already on screen are styled by this call and not by the next
		kill.
	]]
	MatchController.observe({ "Players" }, restyleAll)
	MatchController.observe({ "ModeId" }, restyleAll)

	log.debug("drawing kill codes from codeVisibility")
end

return CodeDisplayController
