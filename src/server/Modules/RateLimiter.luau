--!strict
--[[
	Per-player minimum interval between accepted actions.

		local submitLimit = RateLimiter.new(Config.RateLimit.CodeSubmit)

		Net.submitCode.listen(function(data, player)
			if not submitLimit.allow(player) then
				return   -- drop, silently and with no work done
			end
			...
		end)

	A plain module (ARCHITECTURE.md Recipe 3), server-side because that is the
	only side where a limit means anything -- a client-side limiter is a
	suggestion an exploiter deletes.

	WHY THIS EXISTS RATHER THAN A TABLE PER SERVICE

	DevService already carries its own `lastCommandAt` table and its own
	PlayerRemoving cleanup (DevService.luau). One more service doing that is a
	convention; six more is six chances to forget the cleanup line, and a
	{[Player]: number} that nothing clears is a reference to every player who
	has ever been in the server -- a leak that grows all session and is
	invisible until a long-running server starts swapping.

	Here, the cleanup is written once. Every limiter created through
	RateLimiter.new is registered below, and ONE PlayerRemoving connection
	clears that player out of all of them. A service using this cannot forget,
	because there is nothing for it to remember.

	WHAT IT DELIBERATELY IS NOT

	Not a token bucket, and not a burst allowance. A burst is the right tool
	when a legitimate client genuinely batches -- none of ours does. Every
	packet this guards is one human action (a key press, a button tap), so a
	flat floor is both the simplest thing that works and the easiest to reason
	about when tuning: "at most one every N seconds" has exactly one number in
	it.

	DROP, DO NOT REPLY. A caller that answers a rate-limited packet with an
	error packet has built an amplifier: the flood now costs the server an
	outbound send per inbound packet. Return false, do nothing, and log
	nothing -- logging every drop just relocates the flood into the output
	panel, the point DevService.luau's header makes about running the limit
	before the authority check.
]]

local Players = game:GetService("Players")

export type Limiter = {
	--[[
		True if enough time has passed since this player's last ACCEPTED call,
		and records the acceptance. False otherwise, and records nothing -- a
		refused call must not push the next allowed one further away, or a
		flood would lock a player out for as long as it lasted.
	]]
	allow: (player: Player) -> boolean,
	--[[
		Forgets a player's timestamp early. Optional -- PlayerRemoving already
		does this. Use it when a player should get a clean slate mid-session,
		e.g. on respawn.
	]]
	forget: (player: Player) -> (),
}

type Entry = { [Player]: number }

local RateLimiter = {}

--[[
	Every live limiter's backing table. A plain (strong) table: limiters are
	created at module scope by long-lived services and are never discarded, so
	there is nothing here for weak keys to collect. The table that WOULD grow
	without bound is the per-player one inside each entry, and that is exactly
	what the connection below clears.
]]
local registry: { Entry } = {}

Players.PlayerRemoving:Connect(function(player: Player)
	for _, entry in registry do
		entry[player] = nil
	end
end)

--[[
	`minInterval` is in seconds and must be finite and non-negative. A limiter
	of 0 allows everything, which is a legitimate way to disable one from
	Config without deleting its call sites.
]]
function RateLimiter.new(minInterval: number): Limiter
	--[[
		Validated here, at creation, rather than trusted. Every caller reads
		this out of Config, and a NaN or a negative that slipped into Config
		would otherwise turn a rate limit into a no-op that still LOOKS
		present at every call site -- the worst possible failure for a
		security control. NaN is rejected explicitly because `n < 0` is false
		for NaN (quality-gate.md trap #8).
	]]
	if type(minInterval) ~= "number" or minInterval ~= minInterval or minInterval < 0 or minInterval == math.huge then
		error(`[RateLimiter] minInterval must be a finite number >= 0, got {tostring(minInterval)}`, 2)
	end

	local lastAt: Entry = {}
	table.insert(registry, lastAt)

	local limiter: Limiter = {
		allow = function(player: Player): boolean
			--[[
				os.clock, not tick or os.time. It is monotonic per machine and
				has microsecond resolution; os.time has one-second resolution,
				which would make any interval below 1s either always-allow or
				always-deny depending on where the second boundary fell.
			]]
			local now = os.clock()
			local previous = lastAt[player]
			if previous ~= nil and now - previous < minInterval then
				return false
			end
			lastAt[player] = now
			return true
		end,

		forget = function(player: Player)
			lastAt[player] = nil
		end,
	}

	return limiter
end

return RateLimiter
