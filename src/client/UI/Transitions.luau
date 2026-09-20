--!strict
--[[
	How a screen shows and hides.

	Everything runs through one idea: `Transitions.begin(root, name)` returns a
	*pose* function, and a pose maps one number onto properties --

		alpha 0 = fully shown (exactly as authored in Studio)
		alpha 1 = fully hidden

	-- with nothing in between remembered. The caller tweens alpha (see
	Motion.value) and this decides what alpha means.

	Poses instead of animations is the load-bearing choice. Reopening a
	half-closed menu is just "tween alpha the other way from wherever it is":
	there is no in-flight animation to reverse, no start value to recompute, and
	no state that can disagree with the screen. The alternative -- a show()
	animation and a hide() animation that each own the property -- is where
	menus get stuck half-faded, because the two of them have to negotiate and
	they only ever meet during a bug.

	A ScreenGui cannot fade: it has no transparency. So "fade" means walking the
	tree and moving every transparency property proportionally toward 1 --
	proportionally, so an element authored at 0.5 fades 0.5 -> 1 rather than
	popping to opaque first. A CanvasGroup short-circuits that whole walk, which
	is why it is worth using for a busy screen.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Scaling = require(script.Parent.Scaling)

local log = Log.new("Transitions")

export type Name = "Fade" | "Scale" | "SlideUp" | "SlideDown" | "SlideLeft" | "SlideRight" | "None"

export type Pose = (alpha: number) -> ()

local DEFAULT: Name = "Scale"

local VALID: { [string]: boolean } = {
	Fade = true,
	Scale = true,
	SlideUp = true,
	SlideDown = true,
	SlideLeft = true,
	SlideRight = true,
	None = true,
}

-- Hidden-state scale for "Scale". Deliberately shallow: a menu that shrinks to
-- nothing reads as a bug rather than a transition.
local SCALE_FROM = 0.92

-- Slide distance as a fraction of the viewport, so it is resolution-independent
-- and does not depend on where the panel happens to sit. Named for the direction
-- the screen ENTERS -- "SlideUp" comes up from below -- because that is how
-- every motion spec and CSS name them.
local SLIDE_DISTANCE = 0.06

local SLIDE_OFFSETS: { [string]: Vector2 } = {
	SlideUp = Vector2.new(0, SLIDE_DISTANCE),
	SlideDown = Vector2.new(0, -SLIDE_DISTANCE),
	SlideLeft = Vector2.new(SLIDE_DISTANCE, 0),
	SlideRight = Vector2.new(-SLIDE_DISTANCE, 0),
}

type Prepared = {
	root: GuiObject,
	basePosition: UDim2,
	uiScale: UIScale,
	-- Authored transparency, per instance per property. Rebuilt on every
	-- transition -- see begin().
	originals: { [Instance]: { [string]: number } },
}

type Fade = {
	instance: Instance,
	property: string,
	original: number,
}

local prepared: { [GuiObject]: Prepared } = {}

local NOOP_POSE: Pose = function() end

local Transitions = {}

--[[
	Which properties make this instance disappear. Order matters: CanvasGroup IsA
	Frame, and every text/image class IsA GuiObject, so the specific cases have to
	come first or everything collapses to BackgroundTransparency.
]]
local function fadeProperties(instance: Instance): { string }?
	if instance:IsA("CanvasGroup") then
		return { "GroupTransparency" }
	elseif instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
		return { "BackgroundTransparency", "TextTransparency", "TextStrokeTransparency" }
	elseif instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
		return { "BackgroundTransparency", "ImageTransparency" }
	elseif instance:IsA("ScrollingFrame") then
		return { "BackgroundTransparency", "ScrollBarImageTransparency" }
	elseif instance:IsA("GuiObject") then
		return { "BackgroundTransparency" }
	elseif instance:IsA("UIStroke") then
		return { "Transparency" }
	end
	return nil
end

local function collect(instance: Instance, out: { Instance })
	if fadeProperties(instance) ~= nil then
		table.insert(out, instance)
	end

	if instance:IsA("CanvasGroup") then
		-- GroupTransparency already composites everything below it. Descending
		-- would fade each child a second time, so the group would hit invisible
		-- long before alpha reached 1.
		return
	end

	for _, child in instance:GetChildren() do
		collect(child, out)
	end
end

--[[
	Snapshots the authored pose and gives the root its responsive UIScale.

	Must run before anything animates the screen: every value read here is read
	on the assumption that only the author has ever written it.
]]
function Transitions.prepare(root: GuiObject)
	if prepared[root] ~= nil then
		return
	end

	prepared[root] = {
		root = root,
		basePosition = root.Position,
		-- Every managed screen gets its UIScale for free. This is what
		-- Scaling.luau's header asks for -- one UIScale per ScreenGui root --
		-- and there is no reason to make each screen ask for it by hand.
		uiScale = Scaling.attach(root),
		originals = {},
	}
end

function Transitions.forget(root: GuiObject)
	prepared[root] = nil
end

--[[
	Validates a `Transition` attribute, which is author-typed text and therefore
	arrives misspelled sooner or later.
]]
function Transitions.resolve(value: any): Name
	if value == nil then
		return DEFAULT
	end
	if type(value) == "string" and VALID[value] then
		return value :: Name
	end
	log.warn(`unknown transition {typeof(value)} "{tostring(value)}" -- using "{DEFAULT}"`)
	return DEFAULT
end

--[[
	Starts a transition and returns the pose to drive.

	The tree walk and the transparency snapshot happen here, once. They have to:
	the pose runs every frame, and walking a menu's descendants sixty times a
	second to re-derive constants would be the most expensive thing in the UI.
]]
function Transitions.begin(root: GuiObject, name: Name): Pose
	local entry = prepared[root]
	if entry == nil then
		log.warn(`{root:GetFullName()} was never prepared -- transition skipped`)
		return NOOP_POSE
	end
	if name == "None" then
		return NOOP_POSE
	end

	local targets: { Instance } = {}
	collect(root, targets)

	--[[
		Rebuild the snapshot per transition rather than once in prepare(), and
		carry forward what we already know. Both halves are about dynamic
		content, which is the normal state of a shop or an inventory:

		  A row cloned in since the last transition is not in the old snapshot.
		  Capturing it now is correct precisely BECAUSE it is new -- nothing has
		  touched it, so whatever it reads is what the author set. Capturing a
		  row we already know would instead read whatever mid-fade value it
		  happens to hold, and bake it in as "authored" forever.

		  A row destroyed since the last transition is not in `targets`, so it is
		  not copied across. The table tracks the live tree rather than every
		  instance the screen has ever had, which is why this needs no weak keys
		  and no cleanup pass.
	]]
	local previous = entry.originals
	local originals: { [Instance]: { [string]: number } } = {}
	local fades: { Fade } = {}

	for _, instance in targets do
		local remembered = previous[instance]
		if remembered == nil then
			remembered = {}
			for _, property in fadeProperties(instance) :: { string } do
				remembered[property] = (instance :: any)[property]
			end
		end
		originals[instance] = remembered

		for property, original in remembered do
			table.insert(fades, {
				instance = instance,
				property = property,
				original = original,
			})
		end
	end
	entry.originals = originals

	local offset = SLIDE_OFFSETS[name]
	local scaled = name == "Scale"

	return function(alpha: number)
		for _, fade in fades do
			local target = fade.instance :: any
			-- Clamped because "pop" overshoots both ends of alpha, and a
			-- transparency of -0.1 is not a thing.
			target[fade.property] = math.clamp(fade.original + (1 - fade.original) * alpha, 0, 1)
		end

		if offset ~= nil then
			entry.root.Position = entry.basePosition + UDim2.fromScale(offset.X * alpha, offset.Y * alpha)
		elseif scaled then
			-- Through Scaling, never straight onto UIScale.Scale: Scaling owns
			-- that property, and poses ask for it via setMultiplier.
			Scaling.setMultiplier(entry.uiScale, 1 - (1 - SCALE_FROM) * alpha)
		end
	end
end

return Transitions
