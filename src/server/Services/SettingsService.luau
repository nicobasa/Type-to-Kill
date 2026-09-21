--!strict
--[[
	The two persisted client preferences: MusicEnabled and DarkFlashEffect.

	The whole service is a whitelist, a rate limit and one DataService.set, and
	it is the only thing allowed to turn a Net.setSetting request into a
	profile write.

	WHY A LITERAL WHITELIST RATHER THAN "is the key already in Settings?"

	`key` is an arbitrary client-chosen string, and Settings is a table Replica
	ships to the owning client and ProfileStore saves into a 4MB-capped
	DataStore key. Accepting any key makes the SHAPE of Settings client-chosen:
	the profile grows one key per distinct string anyone ever sends, each one
	persists through every future session, and nothing on either side reads
	them back.

	The obvious alternative -- accept a key only if Settings already holds one
	-- looks equivalent and is not. A dev console write can plant a fresh key
	in Settings (validatePath only requires the PARENT to exist and
	typeMatches permits any type when the existing value is nil,
	DevService.luau), and from that moment the planted key is client-writable
	for good. It also inherits the dotted-key hazard Validate.luau's header
	records: ReplicaClient keys its OnSet listeners by table.concat(path, "."),
	so a key containing a dot collides with a nested path. A table literal in
	this file cannot be widened at runtime by anything.

	No per-player state lives here, so there is nothing to clear on
	PlayerRemoving. The only {[Player]: T} in play belongs to the limiter, and
	RateLimiter clears every limiter it handed out from one connection of its
	own (RateLimiter.luau).

	NOTHING IS EVER SENT BACK -- and the settings UI must be built knowing it.

	Accepted, rate-limited and rejected all look identical on the wire: no
	packet. A toggle that flips itself optimistically and waits for a server
	reply waits forever. The acknowledgement already exists and is the replica:
	DataController.observe({"Settings","MusicEnabled"}, ...) fires immediately
	with the current value and again on every change, so a switch DRIVEN from
	that observer -- rather than from its own click -- shows the persisted
	truth, and a write the limiter swallowed simply never moves it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local DataService = require(script.Parent.DataService)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)

local log = Log.new("SettingsService")

--[[
	The writable keys, and the entirety of this service's authority.

	Every key here must also exist in DataService's TEMPLATE with a boolean
	default: Replica writes into an existing parent table and does not
	auto-vivify, and a key the template never seeded is a key Reconcile never
	backfills onto older profiles -- so it would read as nil for exactly the
	players who have played longest.
]]
local WRITABLE_KEYS: { [string]: boolean } = {
	MusicEnabled = true,
	DarkFlashEffect = true,
}

local writeLimit = RateLimiter.new(Config.RateLimit.SettingWrite)

local SettingsService = {}

local function onSetSetting(data: { key: string, enabled: boolean }, player: Player)
	--[[
		The limiter runs first -- before the whitelist lookup and before any
		logging. A flood of keys that will be rejected anyway must cost nothing,
		and an unknown key is dropped rather than answered for the same reason:
		a reply per rejected packet turns a flood into an amplifier
		(RateLimiter.luau, "drop, do not reply").
	]]
	if not writeLimit.allow(player) then
		return
	end

	if not WRITABLE_KEYS[data.key] then
		-- The key is deliberately not interpolated into the line. It is an
		-- unbounded client-chosen string, and the output panel is not the place
		-- to render one.
		log.debug(`{player.Name} asked to write a setting that is not writable -- dropped`)
		return
	end

	--[[
		ByteNet.bool can only ever decode to true or false, so this cannot fire
		against today's packet. It is here because Net.setSetting is one edit
		away from a wider value type, and on that day this is what keeps a
		non-boolean out of a replicated field every reader treats as a boolean.
	]]
	if type(data.enabled) ~= "boolean" then
		log.warn(`{player.Name} sent a non-boolean setting value -- rejected`)
		return
	end

	if DataService.getData(player) == nil then
		-- Toggled before the profile finished loading, or after it ended.
		-- DataService.set would drop the write anyway; catching it here keeps a
		-- benign join race out of the warn channel.
		log.debug(`setSetting from {player.Name} with no loaded data -- dropped`)
		return
	end

	DataService.set(player, { "Settings", data.key }, data.enabled)
end

--[[
	Init, not Start: the Loader finishes every Init before any Start runs, so a
	listener registered here cannot miss a packet from a client whose own Start
	has already fired. Nothing below yields.
]]
function SettingsService.Init()
	Net.setSetting.listen(function(data, player)
		-- ByteNet types the sender as Player? because a server-sent packet has
		-- none. There is no such thing as a setting write with no owner.
		if player == nil then
			return
		end
		onSetSetting(data, player)
	end)
end

function SettingsService.Start()
	log.info("ready")
end

return SettingsService
