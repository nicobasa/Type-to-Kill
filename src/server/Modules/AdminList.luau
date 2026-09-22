--!strict
--[[
	The admins, by UserId. Server-only (ServerStorage.Modules), so no client
	ever receives the list; a client is only TOLD whether it is on it
	(Net.adminAccess), and AdminService re-checks every admin packet.

	These two are the game's owners and are always admins. Anyone else can be
	made an admin without a code change through the Creator Dashboard: Configs
	-> key `developers`, JSON { "userIds": [...] } (AdminService reads it live).
	Keep this list to the people who must never lose access even if that config
	is broken or deleted.
]]

local ADMINS: { [number]: true } = {
	[90154876] = true,
	[2718068116] = true,
}

return table.freeze(ADMINS)
