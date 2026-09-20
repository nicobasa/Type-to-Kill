--!strict
--[[
	Owns the one UIScale per ScreenGui root, and hands it to transitions to drive.

	It does NOT derive a scale from the viewport, and must not: the screens are
	authored in SCALE, so a root sized {0.6,0},{0.6,0} is already 60% of any
	viewport. A viewport-derived UIScale on top of that is a second responsive
	factor, and the two multiply -- 60% of the screen on desktop, 33% on a phone,
	the UI getting relatively smaller the smaller the screen gets.

	The trade this makes: text, padding and strokes render at their authored size
	on every resolution instead of scaling with the panel. Offset-authored roots
	are what would justify bringing viewport scaling back here.
]]

local Scaling = {}

--[[
	Attaches the root's UIScale, adopting one the author already placed there.
]]
function Scaling.attach(root: GuiObject): UIScale
	local uiScale = root:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	uiScale.Scale = 1
	uiScale.Parent = root
	return uiScale
end

--[[
	Sets the transient transition factor -- an open transition, a hover pop.
	Pass 1 to clear it.
]]
function Scaling.setMultiplier(uiScale: UIScale, multiplier: number)
	uiScale.Scale = multiplier
end

return Scaling
