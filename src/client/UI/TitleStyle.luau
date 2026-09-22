--!strict
--[[
	Draws a cosmetic title on an authored TextLabel: its text, its colours, and
	its animation (Cosmetics.TitleStyle).

	A plain module (ARCHITECTURE.md Recipe 3), used by every screen that shows a
	title -- the main-menu card, the killcam card, the Inventory, the case
	reveal -- so one title looks identical everywhere.

	WHY THIS CREATES A UIGradient WHEN CODE DOES NOT BUILD UI

	The label is authored in Studio and only found here, as the rules require
	(UI-AND-MOTION.md). The gradient is not layout, it is the title's colour:
	which gradient a label needs depends on which title is equipped, which is
	player data. Authoring one per title in Studio would be sixteen copies of
	a colour table that already lives in Cosmetics.luau. So a label gets at
	most one UIGradient, named TitleGradient, created and removed here and
	nowhere else.

	ONE LOOP FOR EVERY ANIMATED TITLE

	A Heartbeat per label is a connection per label to forget. Instead every
	animated label is a row in `active`, driven by one connection that exists
	only while there is something to animate, at 30 updates a second (smooth
	for a slow slide, half the cost of per-frame). A label that has been
	destroyed drops out on the next tick, so a card destroyed by a PlayerGui
	re-clone cannot leak its animation.

	FLOW IS RECOMPUTED, NOT SCROLLED. A UIGradient's Offset clamps at its ends,
	so sliding one leaves a stretch of flat colour at the edge on every loop.
	Instead the ColorSequence itself is rebuilt each tick from the colours as a
	continuous cycle, shifted by the phase: seamless, and never faster than the
	title's Period. Nothing here flashes; everything is a slide of about a
	second or slower, well clear of the 3Hz photosensitivity band
	(StaminaController, GAMEPLAY.md).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Cosmetics = require(ReplicatedStorage.Shared.Cosmetics)

local GRADIENT_NAME = "TitleGradient"
local UPDATE_INTERVAL = 1 / 30
-- ColorSequence allows at most 20 keypoints; a Flow uses this many.
local FLOW_KEYPOINTS = 16
-- How wide the Shimmer's bright band is, as a fraction of the text.
local SHIMMER_HALF_WIDTH = 0.12
-- Of each Shimmer period, the part the band spends crossing. The rest is a
-- rest, so the sweep reads as a glint rather than a constant crawl.
local SHIMMER_SWEEP_FRACTION = 0.55

local WHITE = Color3.new(1, 1, 1)

export type Handle = {
	stop: () -> (),
}

type Animated = {
	gradient: UIGradient,
	style: Cosmetics.TitleStyle,
	startedAt: number,
}

local TitleStyle = {}

local active: { [TextLabel]: Animated } = {}
local connection: RBXScriptConnection? = nil
local elapsed = 0

-- The colour at `t` (any real number) around the cycle of `colors`.
local function cycleColor(colors: { Color3 }, t: number): Color3
	local count = #colors
	if count == 1 then
		return colors[1]
	end
	local position = (t % 1) * count
	local index = math.floor(position)
	local blend = position - index
	local from = colors[index + 1]
	local to = colors[(index + 1) % count + 1]
	return from:Lerp(to, blend)
end

local function flowSequence(colors: { Color3 }, phase: number): ColorSequence
	local keypoints: { ColorSequenceKeypoint } = {}
	for i = 0, FLOW_KEYPOINTS - 1 do
		local t = i / (FLOW_KEYPOINTS - 1)
		table.insert(keypoints, ColorSequenceKeypoint.new(t, cycleColor(colors, t + phase)))
	end
	return ColorSequence.new(keypoints)
end

local function shimmerSequence(base: Color3, bright: Color3, center: number): ColorSequence
	-- Keypoints must be strictly increasing and inside [0, 1]; the band is
	-- clamped into that range and dropped entirely when it is off the text.
	local points: { ColorSequenceKeypoint } = { ColorSequenceKeypoint.new(0, base) }
	local left = center - SHIMMER_HALF_WIDTH
	local right = center + SHIMMER_HALF_WIDTH
	if right > 0.001 and left < 0.999 then
		if left > 0.001 then
			table.insert(points, ColorSequenceKeypoint.new(left, base))
		end
		if center > 0.001 and center < 0.999 then
			table.insert(points, ColorSequenceKeypoint.new(center, bright))
		end
		if right < 0.999 then
			table.insert(points, ColorSequenceKeypoint.new(right, base))
		end
	end
	table.insert(points, ColorSequenceKeypoint.new(1, base))
	return ColorSequence.new(points)
end

local function paint(entry: Animated, now: number)
	local style = entry.style
	local period = math.max(style.Period or 3, 0.5)
	local phase = ((now - entry.startedAt) / period) % 1

	if style.Kind == "Flow" then
		entry.gradient.Color = flowSequence(style.Colors, phase)
	elseif style.Kind == "Shimmer" then
		local base = style.Colors[1]
		local bright = style.Colors[2] or WHITE
		-- The band sweeps from just off the left edge to just off the right
		-- during the first part of the period, then rests off-text.
		local sweep = math.clamp(phase / SHIMMER_SWEEP_FRACTION, 0, 1)
		local center = -SHIMMER_HALF_WIDTH + sweep * (1 + 2 * SHIMMER_HALF_WIDTH)
		entry.gradient.Color = shimmerSequence(base, bright, center)
	end
end

local function step(delta: number)
	elapsed += delta
	if elapsed < UPDATE_INTERVAL then
		return
	end
	elapsed = 0

	local now = os.clock()
	for label, entry in active do
		-- Destroyed, or its gradient was: forget it rather than write into a
		-- dead instance for the rest of the session.
		if label.Parent == nil or entry.gradient.Parent ~= label then
			active[label] = nil
			continue
		end
		paint(entry, now)
	end

	if next(active) == nil then
		local current = connection
		connection = nil
		if current ~= nil then
			current:Disconnect()
		end
	end
end

local function removeGradient(label: TextLabel)
	active[label] = nil
	local existing = label:FindFirstChild(GRADIENT_NAME)
	if existing ~= nil then
		existing:Destroy()
	end
end

--[[
	Shows `titleId` on `label`: text, colour and animation. An empty or unknown
	id clears the label. Returns a handle whose stop() clears it too; calling
	apply again on the same label replaces whatever was there, so a screen can
	simply re-apply on every change.
]]
function TitleStyle.apply(label: TextLabel, titleId: string?): Handle
	removeGradient(label)

	local title = Cosmetics.title(titleId)
	if title == nil then
		label.Text = ""
		return {
			stop = function() end,
		}
	end

	label.Text = title.Text
	local style = title.Style

	if style.Kind == "Solid" or #style.Colors == 0 then
		label.TextColor3 = style.Colors[1] or WHITE
	else
		-- A UIGradient multiplies the label's own colour, so the label goes
		-- white and the gradient supplies every colour.
		label.TextColor3 = WHITE
		local gradient = Instance.new("UIGradient")
		gradient.Name = GRADIENT_NAME

		if style.Kind == "Gradient" then
			local first = style.Colors[1]
			local last = style.Colors[#style.Colors]
			gradient.Color = ColorSequence.new(first, last)
		else
			local entry: Animated = { gradient = gradient, style = style, startedAt = os.clock() }
			paint(entry, entry.startedAt)
			active[label] = entry
			if connection == nil then
				connection = RunService.Heartbeat:Connect(step)
			end
		end

		gradient.Parent = label
	end

	return {
		stop = function()
			removeGradient(label)
			label.Text = ""
		end,
	}
end

-- The rarity's display name and colour, for a label under a title.
function TitleStyle.applyRarity(label: TextLabel, titleId: string?)
	local title = Cosmetics.title(titleId)
	local rarity = if title ~= nil then Cosmetics.rarity(title.Rarity) else nil
	if rarity == nil then
		label.Text = ""
		return
	end
	label.Text = rarity.DisplayName
	label.TextColor3 = rarity.Color
end

return TitleStyle
