--!strict
--[[
	The six maps, by stable id.

	`Id` is the identity: it is what a vote packet carries, what the round
	replica stores, and what names the Model under ServerStorage.Maps. It never
	changes. `DisplayName` is what a player reads and is free to change on a
	whim -- which is exactly why the two are separate fields. Shipping the
	display string as the identity means renaming "Dockyard" to "The Docks"
	invalidates every vote in flight and every saved preference.

	A plain module (ARCHITECTURE.md Recipe 3), shared because the vote UI draws
	DisplayName while the server resolves Id.

	THIS FILE DOES NOT KNOW WHAT IS IN A MAP. The geometry, the spawn points,
	the pickup nodes and the menu camera rails are authored in Studio as
	instances under ServerStorage.Maps.<Id>, and discovered by tag at load time
	(see Shared.Tags and MapService). Rojo mounts scripts, not models
	(ARCHITECTURE.md, "The map"), so a spawn coordinate written in a Luau file
	is a coordinate nobody can drag in the viewport.
]]

export type MapDefinition = {
	Id: string,
	DisplayName: string,
	-- One line, shown on the vote card. Keep it short enough to read inside
	-- the fifteen seconds a vote lasts.
	Tagline: string,
}

local MapCatalog = {}

MapCatalog.LIST = {
	{ Id = "NeonDistrict", DisplayName = "Neon District", Tagline = "Tight streets, high walkways" },
	{ Id = "ConstructionYard", DisplayName = "Construction Yard", Tagline = "Open ground, scaffold verticality" },
	{ Id = "MetroTerminal", DisplayName = "Metro Terminal", Tagline = "Platforms, pillars, long sightlines" },
	{ Id = "RooftopComplex", DisplayName = "Rooftop Complex", Tagline = "Gaps, cover, nowhere to hide" },
	{ Id = "Dockyard", DisplayName = "Dockyard", Tagline = "Container maze and crane decks" },
	{ Id = "SuburbanBlock", DisplayName = "Suburban Block", Tagline = "Houses, yards, short corners" },
} :: { MapDefinition }

local BY_ID: { [string]: MapDefinition } = {}
for _, definition in MapCatalog.LIST do
	BY_ID[definition.Id] = definition
end

--[[
	Takes `any` deliberately: the caller is usually holding a string that came
	off a vote packet, where the static type proves nothing.
]]
function MapCatalog.byId(id: any): MapDefinition?
	if type(id) ~= "string" then
		return nil
	end
	return BY_ID[id]
end

function MapCatalog.exists(id: any): boolean
	return MapCatalog.byId(id) ~= nil
end

return MapCatalog
