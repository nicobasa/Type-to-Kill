--!strict
--[[
	The cosmetics catalog: cases, the titles inside them, and how rare each
	title is.

	A plain module (ARCHITECTURE.md Recipe 3). Shared because the Shop has to
	show the odds, the Inventory has to draw every title, and the server has to
	roll them -- and all three must agree on exactly the same table.

	WHY THE ODDS ARE HERE AND NOT HIDDEN ON THE SERVER

	Config.luau warns that anything shared reaches every client. For drop odds
	that is the point, not a leak: a case can be bought (and will be buyable
	with Robux), and Roblox requires the odds of a paid random item to be shown
	to the player before they buy. The server still does every roll
	(CosmeticsService); a client knowing the odds changes nothing about what it
	gets.

	HOW A ROLL WORKS: first a rarity, by Weight, then a title uniformly among
	that rarity's titles. So a rarity's odds do not change when a title is added
	to it -- only the chance of each individual title inside it does.

	A title the player already owns is a duplicate: they keep nothing new and
	get the rarity's DuplicateRefund in Cash instead, so a bad roll still pays a
	little.

	Adding a title is one entry in TITLES. Adding a case is one entry in CASES;
	every case today holds every title.
]]

export type RarityId = "Common" | "Rare" | "Epic" | "Legendary" | "Mythic"

export type Rarity = {
	Id: RarityId,
	DisplayName: string,
	-- Relative, not a percentage: they are summed and divided at roll time.
	Weight: number,
	-- The rarity's own colour, for its label and the reveal. Never the only
	-- signal -- the rarity is always spelled out as well.
	Color: Color3,
	DuplicateRefund: number,
}

--[[
	How a title is drawn (TitleStyle.luau on the client):

	  Solid     -- one colour.
	  Gradient  -- a fixed left-to-right blend of Colors.
	  Flow      -- Colors, as a loop (the last blends back into the first),
	               scroll across the text, one full cycle per
	               Period seconds.
	  Shimmer   -- Colors[1] with a bright band of Colors[2] sweeping across
	               once per Period seconds.

	Every animation is a slow slide, never a flash: nothing here changes
	brightness faster than about once a second, well clear of the 3Hz hazard
	band the game already respects (StaminaController, GAMEPLAY.md).
]]
export type StyleKind = "Solid" | "Gradient" | "Flow" | "Shimmer"

export type TitleStyle = {
	Kind: StyleKind,
	Colors: { Color3 },
	-- Seconds per cycle, for Flow and Shimmer.
	Period: number?,
}

export type Title = {
	Id: string,
	-- What is printed on the card.
	Text: string,
	Rarity: RarityId,
	Style: TitleStyle,
}

export type Case = {
	Id: string,
	DisplayName: string,
	Description: string,
	CashPrice: number,
	-- Shown on the Robux button. The button is not wired to a developer
	-- product yet (ShopController); this is only what it will say.
	RobuxPrice: number,
	-- The case's picture on its Shop and Inventory cards, as an asset id
	-- ("rbxassetid://..."). "" until it has one: the card shows a placeholder.
	Image: string,
}

local Cosmetics = {}

Cosmetics.RARITIES = {
	{ Id = "Common", DisplayName = "COMMON", Weight = 55, Color = Color3.fromRGB(190, 198, 210), DuplicateRefund = 40 },
	{ Id = "Rare", DisplayName = "RARE", Weight = 28, Color = Color3.fromRGB(70, 150, 255), DuplicateRefund = 80 },
	{ Id = "Epic", DisplayName = "EPIC", Weight = 12, Color = Color3.fromRGB(175, 90, 255), DuplicateRefund = 160 },
	{
		Id = "Legendary",
		DisplayName = "LEGENDARY",
		Weight = 4,
		Color = Color3.fromRGB(255, 190, 40),
		DuplicateRefund = 300,
	},
	{ Id = "Mythic", DisplayName = "MYTHIC", Weight = 1, Color = Color3.fromRGB(255, 90, 170), DuplicateRefund = 600 },
} :: { Rarity }

local GOLD = Color3.fromRGB(255, 190, 40)
local WHITE_HOT = Color3.fromRGB(255, 248, 220)
local RAINBOW = {
	Color3.fromRGB(255, 80, 80),
	Color3.fromRGB(255, 170, 60),
	Color3.fromRGB(255, 235, 80),
	Color3.fromRGB(90, 230, 120),
	Color3.fromRGB(70, 190, 255),
	Color3.fromRGB(150, 110, 255),
	Color3.fromRGB(255, 100, 210),
}

Cosmetics.TITLES = {
	-- COMMON: one clean colour each.
	{
		Id = "Rookie",
		Text = "Rookie",
		Rarity = "Common",
		Style = { Kind = "Solid", Colors = { Color3.fromRGB(200, 206, 216) } },
	},
	{
		Id = "KeyboardWarrior",
		Text = "Keyboard Warrior",
		Rarity = "Common",
		Style = { Kind = "Solid", Colors = { Color3.fromRGB(150, 220, 170) } },
	},
	{
		Id = "QuickFingers",
		Text = "Quick Fingers",
		Rarity = "Common",
		Style = { Kind = "Solid", Colors = { Color3.fromRGB(240, 200, 150) } },
	},
	{
		Id = "DigitHunter",
		Text = "Digit Hunter",
		Rarity = "Common",
		Style = { Kind = "Solid", Colors = { Color3.fromRGB(160, 200, 240) } },
	},
	{
		Id = "ButtonMasher",
		Text = "Button Masher",
		Rarity = "Common",
		Style = { Kind = "Solid", Colors = { Color3.fromRGB(230, 170, 190) } },
	},

	-- RARE: a fixed two-tone blend.
	{
		Id = "CodeBreaker",
		Text = "Code Breaker",
		Rarity = "Rare",
		Style = { Kind = "Gradient", Colors = { Color3.fromRGB(0, 220, 255), Color3.fromRGB(40, 110, 255) } },
	},
	{
		Id = "SharpEye",
		Text = "Sharp Eye",
		Rarity = "Rare",
		Style = { Kind = "Gradient", Colors = { Color3.fromRGB(120, 255, 200), Color3.fromRGB(30, 170, 255) } },
	},
	{
		Id = "SilentTypist",
		Text = "Silent Typist",
		Rarity = "Rare",
		Style = { Kind = "Gradient", Colors = { Color3.fromRGB(190, 200, 255), Color3.fromRGB(90, 110, 220) } },
	},
	{
		Id = "NumpadNinja",
		Text = "Numpad Ninja",
		Rarity = "Rare",
		Style = { Kind = "Gradient", Colors = { Color3.fromRGB(255, 120, 120), Color3.fromRGB(120, 60, 200) } },
	},

	-- EPIC: colours that flow across the text.
	{
		Id = "HumanKeypad",
		Text = "Human Keypad",
		Rarity = "Epic",
		Style = {
			Kind = "Flow",
			Colors = { Color3.fromRGB(175, 90, 255), Color3.fromRGB(80, 200, 255) },
			Period = 3,
		},
	},
	{
		Id = "SpeedDemon",
		Text = "Speed Demon",
		Rarity = "Epic",
		Style = {
			Kind = "Flow",
			Colors = { Color3.fromRGB(255, 70, 50), Color3.fromRGB(255, 170, 40) },
			Period = 2.5,
		},
	},
	{
		Id = "GhostReader",
		Text = "Ghost Reader",
		Rarity = "Epic",
		Style = {
			Kind = "Flow",
			Colors = { Color3.fromRGB(230, 240, 255), Color3.fromRGB(130, 160, 220) },
			Period = 3.5,
		},
	},

	-- LEGENDARY: gold, with a bright band sweeping across.
	{
		Id = "TheCipher",
		Text = "The Cipher",
		Rarity = "Legendary",
		Style = { Kind = "Shimmer", Colors = { GOLD, WHITE_HOT }, Period = 2.4 },
	},
	{
		Id = "ZeroError",
		Text = "Zero Error",
		Rarity = "Legendary",
		Style = { Kind = "Shimmer", Colors = { Color3.fromRGB(255, 150, 40), WHITE_HOT }, Period = 2.4 },
	},

	-- MYTHIC: the full spectrum, flowing.
	{ Id = "TypeGod", Text = "Type God", Rarity = "Mythic", Style = { Kind = "Flow", Colors = RAINBOW, Period = 4 } },
	{
		Id = "Unreadable",
		Text = "Unreadable",
		Rarity = "Mythic",
		Style = { Kind = "Flow", Colors = RAINBOW, Period = 3 },
	},
} :: { Title }

Cosmetics.CASES = {
	{
		Id = "TitleCase",
		DisplayName = "Title Case",
		Description = "Unlocks a random title.",
		CashPrice = 400,
		RobuxPrice = 49,
		Image = "",
	},
} :: { Case }

local RARITY_BY_ID: { [string]: Rarity } = {}
for _, rarity in Cosmetics.RARITIES do
	RARITY_BY_ID[rarity.Id] = rarity
end

local TITLE_BY_ID: { [string]: Title } = {}
local TITLES_BY_RARITY: { [string]: { Title } } = {}
for _, title in Cosmetics.TITLES do
	TITLE_BY_ID[title.Id] = title
	local bucket = TITLES_BY_RARITY[title.Rarity]
	if bucket == nil then
		bucket = {}
		TITLES_BY_RARITY[title.Rarity] = bucket
	end
	table.insert(bucket, title)
end

local CASE_BY_ID: { [string]: Case } = {}
for _, case in Cosmetics.CASES do
	CASE_BY_ID[case.Id] = case
end

-- The rarities that can actually drop: a rarity with no titles would be a
-- roll that lands on nothing, so it is left out of the odds entirely.
local TOTAL_WEIGHT = 0
for _, rarity in Cosmetics.RARITIES do
	if TITLES_BY_RARITY[rarity.Id] ~= nil then
		TOTAL_WEIGHT += rarity.Weight
	end
end

--[[
	Lookups take `any`: callers are usually holding a string off a packet or
	off the profile replica, neither of which the type system has seen.
]]
function Cosmetics.title(id: any): Title?
	if type(id) ~= "string" then
		return nil
	end
	return TITLE_BY_ID[id]
end

function Cosmetics.case(id: any): Case?
	if type(id) ~= "string" then
		return nil
	end
	return CASE_BY_ID[id]
end

function Cosmetics.rarity(id: any): Rarity?
	if type(id) ~= "string" then
		return nil
	end
	return RARITY_BY_ID[id]
end

--[[
	What a case can drop, rarest last -- what the Shop's preview shows. Every
	case holds every title today; a case with its own pool would filter here,
	and roll() would have to take the same pool.
]]
function Cosmetics.contents(caseId: any): { Title }
	if Cosmetics.case(caseId) == nil then
		return {}
	end
	return Cosmetics.TITLES
end

-- The chance of rolling this rarity from a case, 0..1. What the Shop shows.
-- The same for every case: the rarity weights are global on purpose.
function Cosmetics.rarityChance(id: RarityId): number
	local rarity = RARITY_BY_ID[id]
	if rarity == nil or TITLES_BY_RARITY[id] == nil or TOTAL_WEIGHT <= 0 then
		return 0
	end
	return rarity.Weight / TOTAL_WEIGHT
end

--[[
	One roll: a rarity by weight, then a title uniformly within it. The
	generator is the caller's, so the server can keep its own and nothing else
	in the VM can reseed it (VoteService makes the same argument).
]]
function Cosmetics.roll(random: Random): Title
	local pick = random:NextNumber() * TOTAL_WEIGHT
	for _, rarity in Cosmetics.RARITIES do
		local bucket = TITLES_BY_RARITY[rarity.Id]
		if bucket == nil then
			continue
		end
		pick -= rarity.Weight
		if pick <= 0 then
			return bucket[random:NextInteger(1, #bucket)]
		end
	end
	-- Floating-point slack at the very top of the range lands here.
	local fallback = TITLES_BY_RARITY[Cosmetics.RARITIES[1].Id]
	return fallback[random:NextInteger(1, #fallback)]
end

return Cosmetics
