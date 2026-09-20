--!strict
--[[
	Tween primitives for UI.

	A thin layer over TweenService that adds the two things a UI transition needs
	and TweenService does not give you:

	  1. A cancel handle. Interruption is the NORMAL case in UI -- a player closes
	     a menu 100ms into its open animation. A cancelled tween has to leave the
	     property where it stands, so the next one picks up smoothly, and it must
	     NOT run its completion callback: "close, then immediately reopen" would
	     otherwise race the old close's `Enabled = false` against the new open,
	     and the screen vanishes a frame after appearing.

	  2. `Motion.value`, which tweens one number and lets the caller spread it
	     across many properties. Fading a menu means touching the transparency of
	     every descendant; one tween per instance means N tweens to cancel, N
	     chances to desync, and N objects churned per open. One proxy tween keeps
	     them in lockstep and cancels as a unit.

	There is no motion library here on purpose -- see wally.toml.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("Motion")

export type Preset = "pop" | "snappy" | "smooth"

export type Handle = {
	-- Stops where it is. The completion callback does not run.
	cancel: () -> (),
}

local PRESETS: { [string]: TweenInfo } = {
	-- Back overshoots, which is what makes a panel feel like it arrives rather
	-- than fades in. Only ever use it on the way IN.
	pop = TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out),

	-- Exits and presses. An exit animation is dead time between the player
	-- deciding and the game agreeing, so it should not have personality.
	snappy = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),

	smooth = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
}

local NOOP_HANDLE: Handle = {
	cancel = function() end,
}

local Motion = {}

--[[
	Presets are strings so they can come from a Studio attribute, which means a
	typo arrives at runtime rather than at typecheck. Say so instead of silently
	animating differently to what the name asked for.
]]
function Motion.info(preset: Preset | TweenInfo): TweenInfo
	if typeof(preset) == "TweenInfo" then
		return preset
	end

	local info = PRESETS[preset]
	if info == nil then
		log.warn(`unknown preset "{preset}" -- using "smooth"`)
		return PRESETS.smooth
	end
	return info
end

--[[
	Tweens properties on one instance.

	`onComplete` runs only if the tween reaches its goal. A cancelled tween is
	one that something else took over -- the new owner decides what happens next.
]]
function Motion.tween(
	instance: Instance,
	goal: { [string]: any },
	preset: Preset | TweenInfo,
	onComplete: (() -> ())?
): Handle
	local tween = TweenService:Create(instance, Motion.info(preset), goal)
	local cancelled = false

	tween.Completed:Connect(function(state: Enum.PlaybackState)
		if cancelled or state ~= Enum.PlaybackState.Completed then
			return
		end
		if onComplete ~= nil then
			onComplete()
		end
	end)

	tween:Play()

	return {
		cancel = function()
			if cancelled then
				return
			end
			cancelled = true
			-- Cancel halts in place; it does not rewind. That is the point.
			tween:Cancel()
		end,
	}
end

--[[
	Tweens a single number from `from` to `to`, handing each value to `onUpdate`.

		Motion.value(1, 0, "pop", function(alpha)
			applyPose(alpha)
		end)

	`onUpdate` is called synchronously with `from` before playback starts, so the
	caller never has to set the opening pose itself and then hope the first frame
	agrees.
]]
function Motion.value(
	from: number,
	to: number,
	preset: Preset | TweenInfo,
	onUpdate: (value: number) -> (),
	onComplete: (() -> ())?
): Handle
	onUpdate(from)

	if from == to then
		if onComplete ~= nil then
			onComplete()
		end
		return NOOP_HANDLE
	end

	-- A NumberValue is the cheapest thing TweenService can drive, and Changed on
	-- a value object fires with the value itself and only for Value -- no
	-- property-name dispatch, no filtering.
	local proxy = Instance.new("NumberValue")
	proxy.Value = from

	local connection = proxy.Changed:Connect(onUpdate)
	local tween = TweenService:Create(proxy, Motion.info(preset), { Value = to })
	local cancelled = false

	local function cleanup()
		connection:Disconnect()
		proxy:Destroy()
	end

	tween.Completed:Connect(function(state: Enum.PlaybackState)
		if cancelled then
			return
		end
		cleanup()
		if state == Enum.PlaybackState.Completed and onComplete ~= nil then
			onComplete()
		end
	end)

	tween:Play()

	return {
		cancel = function()
			if cancelled then
				return
			end
			cancelled = true
			tween:Cancel()
			cleanup()
		end,
	}
end

return Motion
