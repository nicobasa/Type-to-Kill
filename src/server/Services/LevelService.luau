--!strict
--[[
	Level and Experience. XP is granted; levels follow automatically.

	The curve lives in Shared.Progression, not here, because the HUD must draw
	the same bar the server rolls over -- one curve or the bar lies. The
	rollover loop lives there too: a loop that fails to terminate in Luau is
	not a per-player bug, it is a server-wide freeze, and that proof is worth
	keeping in one place a reader can see whole.

	resolve() recomputes from absolute (Level, Experience), so it is
	idempotent. That is deliberate: the dev console can write Experience
	directly, bypassing this service entirely, and an absolute recompute
	self-heals on the next grant where a delta-based design would leave a
	permanent inconsistency.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local DataService = require(script.Parent.DataService)
local Log = require(ReplicatedStorage.Shared.Log)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Validate = require(ServerStorage.Modules.Validate)

local log = Log.new("LevelService")

local MAX_EXPERIENCE_GRANT = 1e9

--[[
	Fired after a level-up has been written and replicated, never before.
	`previousLevel` is the level held before the grant; a single grant can
	cross several levels, so `level - previousLevel` is not always 1.
]]
export type LevelUpListener = (player: Player, level: number, previousLevel: number) -> ()

local levelUpListeners: { LevelUpListener } = {}

local LevelService = {}

--[[ Current level, or nil if the player's data is not loaded. Read-only. ]]
function LevelService.getLevel(player: Player): number?
	local data = DataService.getData(player)
	return if data ~= nil then data.Level else nil
end

--[[
	Current XP toward the next level, or nil if not loaded. Read-only.
	Always 0 at MAX_LEVEL -- XP does not accrue past the cap.
]]
function LevelService.getExperience(player: Player): number?
	local data = DataService.getData(player)
	return if data ~= nil then data.Experience else nil
end

--[[
	Subscribe to level-ups. Call from your Init(), never Start(): Start()s are
	spawned in parallel (Loader.luau:143), so a listener registered there can
	miss a level-up caused by a faster Start() elsewhere and there is no replay.

	There is deliberately no unsubscribe. Every plausible subscriber is a
	*Service -- a module-scope singleton that outlives every player -- so there
	is nothing to leak. If a per-player subscriber ever appears, return a
	closure from here; do not reach for a Signal library.
]]
function LevelService.onLevelUp(listener: LevelUpListener)
	table.insert(levelUpListeners, listener)
end

--[[
	Grant experience. `amount` must be a positive finite integer <=
	MAX_EXPERIENCE_GRANT. Any levels earned are applied in the same write.

	Returns true if the grant was accepted and applied; false if the amount was
	rejected or the player has no loaded data.
]]
function LevelService.addExperience(player: Player, amount: number): boolean
	if not Validate.amount(amount, MAX_EXPERIENCE_GRANT) then
		log.warn(`addExperience() on {player.Name} with an invalid amount -- rejected`)
		return false
	end

	local data = DataService.getData(player)
	if data == nil then
		log.debug(`addExperience() on {player.Name} with no loaded data -- dropped`)
		return false
	end

	local previousLevel = data.Level
	--[[
		The gained amount goes INTO resolve rather than being added here.
		resolve sanitises all three inputs, so this file never does unguarded
		arithmetic on profile data -- which matters because the dev console can
		put values in Level and Experience that this service never wrote.
	]]
	local newLevel, newExperience = Progression.resolve(data.Level, data.Experience, amount)

	--[[
		ONE write, not one per level. A set() inside the rollover would fire N
		packets and let the client observe a new level alongside a stale XP --
		an XP bar that visibly jumps backwards. Level and Experience are
		top-level siblings, so {} is their common parent, and setValues with an
		empty path walks zero keys and writes straight into Data
		(ReplicaServer.luau:372-378). One packet; the pair updates as a unit.
	]]
	DataService.setValues(player, {}, { Level = newLevel, Experience = newExperience })

	if newLevel > previousLevel then
		-- AFTER the write: a listener that reads getLevel must see the new
		-- level. Spawned: a listener that yields or errors must not abort a
		-- grant that already committed. Ordering between listeners is undefined.
		for _, listener in levelUpListeners do
			task.spawn(listener, player, newLevel, previousLevel)
		end
	end

	return true
end

function LevelService.Start()
	log.info("ready")
end

return LevelService
