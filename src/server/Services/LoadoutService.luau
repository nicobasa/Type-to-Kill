--!strict
--[[
	The two toolbar slots, and the pickups that fill them.

	SLOTS ARE AN ARRAY WITH NO HOLES, EVER

	`slots` is always exactly Config.Toolbar.SlotCount long and an empty slot
	is the empty string, never nil. Neither reason is style. `#` on a table
	with an embedded nil is undefined in Luau (quality-gate.md trap #9), so a
	sparse toolbar is a length nobody can read; and Net.loadout ships the array
	as it stands, so a hole here is a hole the client has to reason about on
	every draw (Net.luau, `loadout`). Clearing a slot writes "". Nothing in
	this file ever calls table.remove on slots.

	THE SERVER HOLDS THE TOOLBAR

	The client draws slots, it does not own them. GrenadeService spends one
	through consume(), so a client-held count is a client-chosen number of
	grenades. Every change below mutates the server's copy and then pushes the
	whole array back down: it is two strings and an index, sent a handful of
	times a minute, and a diff would buy nothing while needing both sides to
	agree on how to apply it.

	PICKUPS ARE PARTS THIS SERVICE BUILDS

	A pickup is one anchored, non-colliding Part, not a clone of an authored
	model. That buys two things: hiding and restoring a taken pickup touches
	exactly one instance rather than walking a model's descendants, and a map
	is playable the moment its nodes are tagged, before any art exists.
	Swapping in a mesh is a change to createPickupPart and to nothing else.

	They live in a folder this service owns and NOT under Workspace.ActiveMap,
	which MapService destroys on unload. A pickup destroyed out from under us
	leaves a respawn timer running against a part that no longer exists --
	which is a crash in twenty seconds' time, in a service that has long since
	stopped being the obvious suspect.

	A DROPPED ITEM IS A PICKUP ANYONE MAY TAKE

	It does not come back when taken: it is not a node, it is a thing a player
	put down. It is also not collectable for DROP_ARM_DELAY, because it lands
	under the player who dropped it and they are still standing there --
	without that delay, dropping an item hands it straight back and drop is a
	no-op that still costs two packets.

	Per-player state is `loadouts` plus one CharacterAdded connection each, and
	both are cleared in onPlayerRemoving. The limiters clear themselves
	(RateLimiter.luau).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Items = require(ReplicatedStorage.Shared.Items)
local Log = require(ReplicatedStorage.Shared.Log)
local MapService = require(script.Parent.MapService)
local Match = require(ReplicatedStorage.Shared.Match)
local Net = require(ReplicatedStorage.Shared.Net)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local RoundService = require(script.Parent.RoundService)
local Tags = require(ReplicatedStorage.Shared.Tags)

--[[
	Deferred, because ParticipantService requires this module directly -- it
	clears the loadout when a player leaves the match -- and a require at file
	scope here would be the cycle Luau throws on at load. The annotation is
	erased at runtime, so the types resolve and no cycle exists
	(ARCHITECTURE.md, "Using another module").
]]
local ParticipantService: typeof(require(script.Parent.ParticipantService)) = nil :: any

local log = Log.new("LoadoutService")

local SLOT_COUNT = Config.Toolbar.SlotCount

--[[
	Minimum seconds between two evaluations of the same pickup, per pickup.

	Touched fires many times for a single contact -- once per re-evaluation of
	the overlap, which for a running character is several times a second. A
	successful take is already self-limiting (the pickup goes unavailable on
	the first one), so this floor exists for the touch that FAILS: a player
	standing in a pickup with both slots full would otherwise run the whole
	ladder in onPickupTouched for as long as they stand there.
]]
local TOUCH_DEBOUNCE = 0.25

-- See the header: a dropped item must not be collectable by the player still
-- standing on top of it.
local DROP_ARM_DELAY = 1

local PICKUP_SIZE = Vector3.new(2, 2, 2)

-- A node marks the floor, so the item floats above it. Sitting flush with the
-- marker reads as scenery rather than as something to walk into.
local PICKUP_NODE_HOVER = 2

type Loadout = {
	-- Exactly SLOT_COUNT entries, "" for empty. See the header.
	slots: { string },
	selected: number,
}

type Pickup = {
	itemId: string,
	part: BasePart,
	-- False while taken and waiting to come back. A node pickup still exists
	-- as an instance while unavailable; only its visibility and CanTouch move.
	available: boolean,
	-- Node pickups return after Config.Pickups.RespawnDelay. Dropped ones are
	-- destroyed when taken.
	respawns: boolean,
	-- os.clock() before which this pickup refuses every toucher.
	armedAt: number,
	lastTouchAt: number,
	respawnThread: thread?,
}

local loadouts: { [Player]: Loadout } = {}
local characterConnections: { [Player]: RBXScriptConnection? } = {}
local pickups: { Pickup } = {}

--[[
	Two limiters, not one shared "item action" limiter. They guard different
	packets and a player who has just cycled slots must still be able to drop
	in the same breath -- one table would make each action eat the other's
	budget, which reads as the game dropping inputs.
]]
local selectLimit = RateLimiter.new(Config.RateLimit.ItemAction)
local dropLimit = RateLimiter.new(Config.RateLimit.ItemAction)

local pickupsFolder = Instance.new("Folder")
pickupsFolder.Name = "Pickups"

local function emptySlots(): { string }
	return table.create(SLOT_COUNT, "")
end

local function ensureLoadout(player: Player): Loadout
	local existing = loadouts[player]
	if existing ~= nil then
		return existing
	end

	local record: Loadout = { slots = emptySlots(), selected = 1 }
	loadouts[player] = record
	return record
end

--[[
	The hand parts, R15 first. Named rather than found by class because an R15
	RightHand and an R6 "Right Arm" are both plain BaseParts.
]]
local HAND_PART_NAMES = { "RightHand", "Right Arm" }

-- The model in the hand. CameraController matches on this name to keep it
-- visible in first person, so the two must agree.
local HELD_ITEM_NAME = "HeldItem"

--[[
	Where the item sits relative to the hand. Hands hang palm-down, so the
	offset is below the hand's centre; the small forward component puts it in
	the fingers rather than through the wrist.
]]
local HELD_ITEM_OFFSET = CFrame.new(0, -0.55, -0.15)

local function findHand(character: Model): BasePart?
	for _, name in HAND_PART_NAMES do
		local part = character:FindFirstChild(name)
		if part ~= nil and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

--[[
	Put the selected item in the player's hand, or take it out.

	SERVER-SIDE, so every player sees the same grenade in the same hand -- a
	client-drawn one would be a grenade only its owner could see, which is
	exactly backwards for a thing whose whole job is telegraphing "this player
	is about to throw something".

	Rebuilt only when the item CHANGES. The naive version destroys and re-clones
	on every push, and pushLoadout runs on selection, pickup, throw, drop and
	spawn -- the grenade would visibly blink out and back every time the player
	tapped a slot.
]]
local function syncHeldItem(player: Player)
	local character = player.Character
	if character == nil then
		return
	end

	local record = loadouts[player]
	local itemId = if record ~= nil then record.slots[record.selected] or "" else ""

	local existing = character:FindFirstChild(HELD_ITEM_NAME)
	if existing ~= nil then
		if existing:GetAttribute("ItemId") == itemId then
			return
		end
		existing:Destroy()
	end

	if itemId == "" or not Items.exists(itemId) then
		return
	end

	local assets = ServerStorage:FindFirstChild("Assets")
	local itemFolder = if assets ~= nil then assets:FindFirstChild("Items") else nil
	local template = if itemFolder ~= nil then itemFolder:FindFirstChild(itemId) else nil
	if template == nil or not template:IsA("BasePart") then
		-- Cosmetic only: the slot still works and the throw still throws.
		return
	end

	local hand = findHand(character)
	if hand == nil then
		return
	end

	local held = template:Clone()
	held.Name = HELD_ITEM_NAME
	held:SetAttribute("ItemId", itemId)
	held.Anchored = false
	-- A held prop must not collide with the world or be hit by anything that
	-- queries it: it would shove its owner around and block their own raycasts.
	held.CanCollide = false
	held.CanQuery = false
	held.CanTouch = false
	held.Massless = true
	held.CFrame = hand.CFrame * HELD_ITEM_OFFSET
	held.Parent = character

	--[[
		A Weld with an explicit C0, never a WeldConstraint. The constraint
		captures whatever offset exists when it activates, and the hand is
		animated -- CodeService.attachHeadband has the long version of why that
		goes wrong.
	]]
	local weld = Instance.new("Weld")
	weld.Name = "HeldItemWeld"
	weld.Part0 = hand
	weld.Part1 = held
	weld.C0 = HELD_ITEM_OFFSET
	weld.Parent = held
end

--[[
	Tell the client what it is holding, and put it in the character's hand.

	The two are done together on purpose: every caller that changes the loadout
	has to do both, and a version where they were separate would be one call
	site away from a toolbar that says "FLASHBANG" over an empty hand.
]]
local function pushLoadout(player: Player)
	local record = loadouts[player]
	if record == nil then
		return
	end
	Net.loadout.sendTo({ slots = record.slots, selected = record.selected }, player)
	syncHeldItem(player)
end

--[[
	A 1-based index into slots. NaN is rejected explicitly because it fails
	every comparison that follows and would otherwise pass the range check
	(quality-gate.md trap #8) -- `slot` arrives off a packet, where the
	`number` annotation is a promise nobody kept.
]]
local function isSlotIndex(slot: number): boolean
	if type(slot) ~= "number" or slot ~= slot then
		return false
	end
	return math.floor(slot) == slot and slot >= 1 and slot <= SLOT_COUNT
end

local LoadoutService = {}

--[[
	A COPY of the player's slots, always SLOT_COUNT long, "" for empty. A
	player with no record yet (they have never spawned) gets an empty toolbar
	rather than nil, so no caller has to branch on "has this player a loadout".

	The copy is the point: handing out the live array would let any caller
	silently desync the client, because a write through the returned table
	changes the server's truth without ever pushing Net.loadout.
]]
function LoadoutService.getSlots(player: Player): { string }
	local record = loadouts[player]
	if record == nil then
		return emptySlots()
	end
	return table.clone(record.slots)
end

function LoadoutService.getSelected(player: Player): number
	local record = loadouts[player]
	return if record ~= nil then record.selected else 1
end

--[[
	Put `itemId` in the first empty slot. False if every slot is full, or if
	the id names no item in the catalog -- in both cases nothing is written and
	nothing is sent.
]]
function LoadoutService.give(player: Player, itemId: string): boolean
	if not Items.exists(itemId) then
		log.warn(`give() on {player.Name} with an unknown item id -- rejected`)
		return false
	end

	local record = ensureLoadout(player)
	for slot = 1, SLOT_COUNT do
		if record.slots[slot] == "" then
			record.slots[slot] = itemId
			pushLoadout(player)
			return true
		end
	end

	return false
end

--[[
	Take the item out of `slot` and return its id, or nil if the slot is empty
	or the index is not a slot.

	Read and write happen here, in one slice with no yield between them, for
	the reason CashService has no set(): a caller that read a slot, yielded and
	then cleared it could be one of two throw handlers in the same frame, and
	both would spend the same grenade.
]]
function LoadoutService.consume(player: Player, slot: number): string?
	if not isSlotIndex(slot) then
		return nil
	end

	local record = loadouts[player]
	if record == nil then
		return nil
	end

	local itemId = record.slots[slot]
	if itemId == "" then
		return nil
	end

	record.slots[slot] = ""
	pushLoadout(player)
	return itemId
end

function LoadoutService.clear(player: Player)
	local record = loadouts[player]
	if record == nil then
		return
	end

	record.slots = emptySlots()
	record.selected = 1
	pushLoadout(player)
end

--[[
	Empties every toolbar. Deliberately a local and not a member: the public API
	is the five functions above, and nobody calls "reset" on this service -- it
	subscribes to onStateChanged and resets itself, which is why RoundService
	does not know this exists.
]]
local function clearAllLoadouts()
	for player in loadouts do
		LoadoutService.clear(player)
	end
end

--[[
	Tears down one pickup completely. The Touched connection is not tracked and
	does not need to be: it belongs to the part, and Destroy disconnects an
	instance's own event connections (quality-gate.md, Gate 2). Cancelling the
	respawn first is what matters -- a live timer would fire against a
	destroyed part.
]]
local function releasePickup(pickup: Pickup)
	local thread = pickup.respawnThread
	if thread ~= nil then
		-- Safe to cancel unconditionally: the delayed body nils this field as
		-- its first act and never yields, so a thread still referenced here has
		-- not run.
		pickup.respawnThread = nil
		task.cancel(thread)
	end
	pickup.part:Destroy()
end

local function removePickup(pickup: Pickup)
	releasePickup(pickup)
	local index = table.find(pickups, pickup)
	if index ~= nil then
		table.remove(pickups, index)
	end
end

local function despawnPickups()
	for _, pickup in pickups do
		releasePickup(pickup)
	end
	table.clear(pickups)
end

local function takePickup(pickup: Pickup)
	if not pickup.respawns then
		removePickup(pickup)
		return
	end

	pickup.available = false
	pickup.part.Transparency = 1
	pickup.part.CanTouch = false

	pickup.respawnThread = task.delay(Config.Pickups.RespawnDelay, function()
		pickup.respawnThread = nil
		pickup.available = true
		pickup.part.Transparency = 0
		pickup.part.CanTouch = true
	end)
end

local function onPickupTouched(pickup: Pickup, otherPart: BasePart)
	if not pickup.available then
		return
	end

	local now = os.clock()
	if now - pickup.lastTouchAt < TOUCH_DEBOUNCE then
		return
	end
	pickup.lastTouchAt = now

	if now < pickup.armedAt then
		return
	end

	-- FindFirstAncestorOfClass, not otherPart.Parent: a hat or a tool handle
	-- is parented to an Accessory inside the character, and touching one is
	-- still the player touching the pickup.
	local character = otherPart:FindFirstAncestorOfClass("Model")
	if character == nil then
		return
	end

	local player = Players:GetPlayerFromCharacter(character)
	if player == nil then
		return
	end

	-- A pickup is a round object. Someone in the menu or watching a killcam
	-- can be standing in the map; they do not collect.
	if not ParticipantService.isPlaying(player) then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return
	end

	if not LoadoutService.give(player, pickup.itemId) then
		-- Both slots full. The pickup stays exactly where it is, so walking
		-- back after a throw works with no further bookkeeping.
		return
	end

	takePickup(pickup)
end

local function createPickupPart(itemId: string, pivot: CFrame): BasePart
	local definition = Items.byId(itemId)

	local part = Instance.new("Part")
	part.Name = `{itemId}Pickup`
	part.Size = PICKUP_SIZE
	part.CFrame = pivot
	part.Anchored = true
	part.CanCollide = false
	--[[
		CanQuery off, CanTouch on. A pickup must never block a raycast: the
		flashbang's line-of-sight test would count a floating cube as cover and
		spare a player standing in the open (GrenadeService).
	]]
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = if definition ~= nil then definition.Color else Color3.new(1, 1, 1)
	return part
end

--[[
	`respawns` false is a dropped item: gone for good once someone takes it,
	and inert for DROP_ARM_DELAY so its own owner cannot re-take it on the spot.
]]
local function addPickup(itemId: string, pivot: CFrame, respawns: boolean)
	local pickup: Pickup = {
		itemId = itemId,
		part = createPickupPart(itemId, pivot),
		available = true,
		respawns = respawns,
		armedAt = if respawns then 0 else os.clock() + DROP_ARM_DELAY,
		lastTouchAt = 0,
		respawnThread = nil,
	}

	pickup.part.Touched:Connect(function(otherPart: BasePart)
		onPickupTouched(pickup, otherPart)
	end)
	pickup.part.Parent = pickupsFolder

	table.insert(pickups, pickup)
end

local function spawnPickups()
	local nodes = MapService.getPickupNodes()
	if #nodes == 0 then
		-- Warn, never error: a map with no item nodes is a thin map, not a
		-- broken one, and the round must still run on it.
		log.warn(`the loaded map has no {Tags.PICKUP_NODE} parts -- no items will appear this round`)
		return
	end

	for _, node in nodes do
		local definition = Items.byId(node:GetAttribute(Tags.ATTRIBUTE_ITEM_ID))
		if definition == nil then
			--[[
				Skipped, never defaulted. Guessing an item for a node whose
				attribute is missing or misspelled drops a Flashbang somewhere
				the author never asked for AND hides the typo that caused it --
				the node stays visibly empty in game instead, which is the
				report the author needs.
			]]
			log.warn(`{node:GetFullName()} has no usable {Tags.ATTRIBUTE_ITEM_ID} attribute -- skipped`)
			continue
		end
		addPickup(definition.Id, node.CFrame + Vector3.new(0, PICKUP_NODE_HOVER, 0), true)
	end

	log.debug(`spawned {#pickups} pickups`)
end

local function onSelectSlot(data: { slot: number }, player: Player)
	-- The limiter runs before every other check, including the validity of the
	-- index: a flood of nonsense must cost nothing (RateLimiter.luau).
	if not selectLimit.allow(player) then
		return
	end

	if not isSlotIndex(data.slot) then
		return
	end

	local record = loadouts[player]
	if record == nil or record.selected == data.slot then
		return
	end

	-- Selecting an EMPTY slot is legal. The toolbar highlights empty slots
	-- too, and refusing would leave the highlight disagreeing with the key the
	-- player just pressed.
	record.selected = data.slot
	pushLoadout(player)
end

local function onDropItem(data: { slot: number }, player: Player)
	if not dropLimit.allow(player) then
		return
	end

	if not ParticipantService.isPlaying(player) then
		return
	end

	local character = player.Character
	if character == nil then
		return
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if root == nil or not root:IsA("BasePart") or humanoid == nil or humanoid.Health <= 0 then
		return
	end

	-- Consumed before the pickup exists. The other order can give the item away
	-- twice: the new pickup is touchable the instant it is parented, and the
	-- slot it came from is still full until consume() runs.
	local itemId = LoadoutService.consume(player, data.slot)
	if itemId == nil then
		return
	end

	--[[
		The feet, not the root. HumanoidRootPart sits HipHeight plus half its
		own height above the floor, so dropping at the root pivot leaves the
		item hanging at chest level.
	]]
	local ground = root.Position - Vector3.new(0, root.Size.Y / 2 + humanoid.HipHeight, 0)
	addPickup(itemId, CFrame.new(ground + Vector3.new(0, PICKUP_SIZE.Y / 2, 0)), false)
end

local function onStateChanged(state: Match.MatchState, _previous: Match.MatchState)
	if state == "WaitingToPlay" then
		--[[
			MapLoading has finished, so the nodes MapService reports are the new
			map's. Everything resets here rather than at RoundActive because a
			player may already be spawned and walking the map during
			WaitingToPlay -- they are meant to be able to collect before the
			round opens, and they are not meant to still be holding last round's
			grenade while they do it.
		]]
		clearAllLoadouts()
		despawnPickups()
		spawnPickups()
	elseif state == "Lobby" or state == "RoundResults" then
		--[[
			The round is over and the map is about to be unloaded under them.
			Items left up would hang in the air over the lobby, and a node
			pickup that survived into the next map would sit somewhere nobody
			authored.
		]]
		despawnPickups()
	end
end

--[[
	What a fresh character needs: the toolbar GUI is rebuilt with the
	character, and the server's slots are the only copy that counts.

	Nothing here clears the loadout. An item survives a death on purpose -- it
	is lost when the round resets, not when its holder does.
]]
local function onCharacterAdded(player: Player, character: Model)
	ensureLoadout(player)
	pushLoadout(player)

	--[[
		Push again once the hand exists.

		CharacterAdded fires before the limbs have finished replicating, so the
		first push above reliably finds no RightHand and silently skips the held
		model -- and since pushLoadout only runs on CHANGES, nothing would come
		along later to fix it. A player who spawned already holding a grenade
		would see an empty hand until they picked up or threw something.

		Spawned so the signal handler does not yield, and bounded so a character
		that never gets a hand costs one dead thread rather than a parked one.
		The re-check that the character is still the current one matters: at
		Config.Killcam.Duration a player can die and respawn inside this wait.
	]]
	task.spawn(function()
		if character:WaitForChild("RightHand", 5) == nil and character:FindFirstChild("Right Arm") == nil then
			return
		end
		if player.Character ~= character then
			return
		end
		syncHeldItem(player)
	end)
end

local function onPlayerAdded(player: Player)
	if characterConnections[player] ~= nil then
		return
	end

	characterConnections[player] = player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)
end

local function onPlayerRemoving(player: Player)
	local connection = characterConnections[player]
	if connection ~= nil then
		connection:Disconnect()
		characterConnections[player] = nil
	end

	-- Not clear(): there is nobody left to push the empty toolbar to, and a
	-- {[Player]: T} nothing deletes from is a reference to every player who has
	-- ever been in the server.
	loadouts[player] = nil
end

--[[
	Init, not Start: the Loader finishes every Init before any Start runs, so a
	listener registered here cannot miss a packet from a client whose own Start
	has already fired, and onStateChanged is subscribed before the round loop
	takes its first step. Nothing below yields.
]]
function LoadoutService.Init()
	ParticipantService = require(script.Parent.ParticipantService)

	pickupsFolder.Parent = workspace

	RoundService.onStateChanged(onStateChanged)

	Net.selectSlot.listen(function(data, player)
		-- ByteNet types the sender as Player? because a server-sent packet has
		-- none. There is no such thing as an ownerless toolbar action.
		if player == nil then
			return
		end
		onSelectSlot(data, player)
	end)

	Net.dropItem.listen(function(data, player)
		if player == nil then
			return
		end
		onDropItem(data, player)
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

function LoadoutService.Start()
	-- Players already in the server when this loads: in Studio the first player
	-- exists before the Loader has run, and their CharacterAdded would
	-- otherwise never be wired.
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)

		--[[
			A character that ALREADY exists fired its CharacterAdded before the
			connection above was made, so its push has to be made by hand --
			without it that player holds a toolbar the client never drew until
			they next respawn, which in a solo Studio session is the whole
			round.

			Sending here is safe for the reason the send itself is conditional:
			a character exists, so this player joined long enough ago that
			ByteNet's own PlayerAdded handler has allocated their send channel.
			Sending on the join frame is the race DevService.luau documents.
		]]
		local character = player.Character
		if character ~= nil then
			onCharacterAdded(player, character)
		end
	end

	log.info("ready")
end

return LoadoutService
