--!strict
--[[
	The level/XP curve, and the rollover loop that walks it.

	Shared, not server-only: the HUD has to draw an XP bar, which needs "how
	much XP does this level require?", and the server has to roll levels over
	on grant, which needs the identical answer. If the curve lived only on the
	server it would either have to be replicated (extra data, extra drift) or
	hand-duplicated on the client -- two curves that diverge on the first
	balance tweak, and the bar starts lying. This is a genuine both-sides need
	(ARCHITECTURE.md:12), not an exception to the shared-folder rule.

	A plain module, not a *Service -- the name ends in neither Service nor
	Controller, so the Loader ignores it entirely (ARCHITECTURE.md Recipe 3).
	Require it directly. It has zero dependencies, not even Log: it is pure
	arithmetic, and a require of Log here would drag a logger into the
	client's render path for no reason.
]]

local BASE_EXPERIENCE = 100 -- XP to go from level 1 to level 2
local EXPERIENCE_STEP = 50 -- added per level thereafter
local MAX_EXPERIENCE_VALUE = 1e12 -- sanitisation clamp -- see the ceiling note below

local Progression = {}

Progression.MIN_LEVEL = 1
Progression.MAX_LEVEL = 100

--[[
	NaN defeats math.clamp -- both of its comparisons are false -- so NaN is
	rejected BEFORE the clamp, never after (quality-gate.md trap #8).
]]
local function sanitizeLevel(level: number): number
	if type(level) ~= "number" or level ~= level then
		return Progression.MIN_LEVEL
	end
	-- math.floor(math.huge) is math.huge, so the clamp -- not the floor -- is
	-- what makes infinity finite here. Order matters.
	return math.clamp(math.floor(level), Progression.MIN_LEVEL, Progression.MAX_LEVEL)
end

local function sanitizeExperience(experience: number): number
	if type(experience) ~= "number" or experience ~= experience then
		return 0
	end
	return math.clamp(math.floor(experience), 0, MAX_EXPERIENCE_VALUE)
end

--[[
	XP required to advance FROM `level` TO `level + 1`.

	Total function: returns a finite integer in [BASE_EXPERIENCE, 5050] for
	EVERY input, including nil-ish garbage, NaN and math.huge. That totality is
	load-bearing -- resolve()'s termination proof depends on this never being
	zero, negative or NaN, and this module is reachable from the client, where
	the inputs are whatever the replica happens to hold.
]]
function Progression.experienceForLevel(level: number): number
	return BASE_EXPERIENCE + EXPERIENCE_STEP * (sanitizeLevel(level) - 1)
end

--[[ True only for a real number >= MAX_LEVEL. NaN >= MAX_LEVEL is false, so
	NaN reports false, which is the safe answer for a HUD. ]]
function Progression.isMaxLevel(level: number): boolean
	return type(level) == "number" and level >= Progression.MAX_LEVEL
end

--[[
	Fraction of the way to the next level, in [0, 1]. For the HUD bar.
	Returns exactly 1 at MAX_LEVEL, and 0 for any unusable input.
]]
function Progression.progress(level: number, experience: number): number
	if Progression.isMaxLevel(level) then
		return 1
	end
	-- experienceForLevel is total and never returns 0, so this cannot divide
	-- by zero for any input. That is the whole reason it is written to be total.
	return math.clamp(sanitizeExperience(experience) / Progression.experienceForLevel(level), 0, 1)
end

--[[
	The rollover. Pure: no player, no data, no side effects. Given a current
	level, a current experience, and an amount gained, returns the resolved
	(level, experience).
]]
function Progression.resolve(level: number, experience: number, gained: number): (number, number)
	local newLevel = sanitizeLevel(level)
	local newExperience = sanitizeExperience(experience) + sanitizeExperience(gained)

	--[[
		TERMINATION, proved rather than asserted: newLevel increments on every
		iteration and is bounded above by MAX_LEVEL, so this runs at most
		MAX_LEVEL - MIN_LEVEL times -- 99 -- for ANY input. Not "in practice":
		for any input. A curve bug that returned 0, a NaN experience, or an
		infinite experience each still terminate here.

		That bound is why there is no iteration counter. Binding the loop to XP
		consumption instead (`while newExperience >= needed`) is what makes a
		zero-returning curve an infinite loop, and an infinite loop in Luau is
		not a per-player bug -- it never yields, so it hangs the server for
		everyone. Do not relax this condition.
	]]
	while newLevel < Progression.MAX_LEVEL do
		local needed = Progression.experienceForLevel(newLevel)
		if newExperience < needed then
			break
		end
		newExperience -= needed
		newLevel += 1
	end

	if newLevel >= Progression.MAX_LEVEL then
		-- XP does not accrue past the cap. Left to accumulate it would walk
		-- into 2^53, where n + 1 == n and XP silently stops rising forever.
		newExperience = 0
	end

	return newLevel, newExperience
end

return Progression
