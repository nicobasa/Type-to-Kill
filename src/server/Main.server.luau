--!strict
--[[
	Server entry point. The ONLY script in ServerScriptService.
	Everything else lives in ServerStorage.Services and is loaded from here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)

-- Rojo owns this folder. A plain `ServerStorage.Services` would raise
-- "Services is not a valid member of ServerStorage", which says nothing about
-- the actual cause -- almost always a place that hasn't synced the current
-- default.project.json yet.
local services = ServerStorage:FindFirstChild("Services")
if services == nil then
	error(
		"[Main] ServerStorage.Services is missing.\n"
			.. "The place is out of sync with default.project.json.\n"
			.. "Fix: run `rojo serve`, connect the Rojo plugin in Studio, then Play.",
		0
	)
end

Loader.load({ services })
