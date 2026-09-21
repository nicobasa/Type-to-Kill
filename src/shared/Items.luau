--!strict
--[[
	The throwable items, by stable id.

	Same Id/DisplayName split as MapCatalog, for the same reason: `Id` is what
	crosses the wire, names the model under ServerStorage.Assets.Items and keys
	a pickup node's `ItemId` attribute; `DisplayName` is what a player reads.

	A plain module (ARCHITECTURE.md Recipe 3). Shared because the toolbar draws
	slots from it while the server decides what a throw actually does.

	Timings and ranges are NOT here -- they are in Config.Flash / Config.Smoke,
	so every tunable number in the game stays in one file. This module is the
	catalog: what exists, what it is called, what colour its slot is.

	Adding a third item is this table plus a branch in GrenadeService.detonate.
	Nothing in the toolbar, the pickup system or the HUD needs to change.
]]

export type ItemId = "Flashbang" | "SmokeGrenade"

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
