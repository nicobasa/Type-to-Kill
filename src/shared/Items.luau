--!strict
--[[
	The throwable items, by stable id.

	Same Id/DisplayName split as MapCatalog, for the same reason: `Id` is what
	crosses the wire, names the model under ServerStorage.Assets.Items and keys
	a pickup node's `ItemId` attribute; `DisplayName` is what a player reads.

	A plain module (ARCHITECTURE.md Recipe 3). Shared because the toolbar draws
	slots from it while the server decides what a throw actually does.

	Timings and ranges are NOT here -- they are in Config.Flash / Config.Smoke /
	Config.Frag / Config.Shock / Config.Impulse, so every tunable number in the
	game stays in one file. This
	module is the catalog: what exists, what it is called, what colour its slot
	is.

	Adding an item is this table plus a row in GrenadeService's GRENADES table.
	Nothing in the toolbar or the HUD needs to change. Pickups are authored per
	map in Studio (a node's ItemId attribute), so a new item only shows up on
	the maps whose nodes name it.
]]

export type ItemId = "Flashbang" | "SmokeGrenade" | "FragGrenade" | "ShockGrenade" | "ImpulseGrenade"

export type ItemDefinition = {
	Id: ItemId,
	DisplayName: string,
	-- Two or three characters for the toolbar slot, which is a small square.
	ShortName: string,
	-- Slot accent. Never the only signal -- the slot also carries ShortName,
	-- for the same reason team colours are always spelled out.
	Color: Color3,
}

local Items = {}

Items.LIST = {
	{
		Id = "Flashbang",
		DisplayName = "Flashbang",
		ShortName = "FLS",
		Color = Color3.fromRGB(245, 226, 140),
	},
	{
		Id = "SmokeGrenade",
		DisplayName = "Smoke Grenade",
		ShortName = "SMK",
		Color = Color3.fromRGB(150, 160, 175),
	},
	{
		Id = "FragGrenade",
		DisplayName = "Frag Grenade",
		ShortName = "FRG",
		-- Olive, the colour anyone reads as a frag. Not the stun effect's
		-- yellow: the slot and the effect are different things to look for.
		Color = Color3.fromRGB(122, 150, 80),
	},
	{
		Id = "ShockGrenade",
		DisplayName = "Shock Grenade",
		ShortName = "SHK",
		-- Electric blue, the colour of the arcs it leaves on the players it hits.
		Color = Color3.fromRGB(90, 190, 255),
	},
	{
		Id = "ImpulseGrenade",
		DisplayName = "Impulse Grenade",
		ShortName = "IMP",
		-- Magenta: the colour of its shockwave, and nothing else in the game.
		Color = Color3.fromRGB(235, 90, 220),
	},
} :: { ItemDefinition }

local BY_ID: { [string]: ItemDefinition } = {}
for _, definition in Items.LIST do
	BY_ID[definition.Id] = definition
end

--[[
	Takes `any`: callers are usually holding a string off a packet or off a
	Studio-authored `ItemId` attribute, neither of which the type system has
	ever seen.
]]
function Items.byId(id: any): ItemDefinition?
	if type(id) ~= "string" then
		return nil
	end
	return BY_ID[id]
end

function Items.exists(id: any): boolean
	return Items.byId(id) ~= nil
end

return Items
