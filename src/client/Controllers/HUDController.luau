--!strict
--[[
	One line: what this controller owns.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataController = require(script.Parent.DataController)
local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("HUDController")

local player = Players.LocalPlayer

local HUDController = {}

function HUDController.Init()
	-- Replica.OnNew and other "must exist before data arrives" listeners go HERE.
	-- Main.client.luau calls Replica.RequestData() only after every Init() has run.
end

function HUDController.Start()
	DataController.observe({ "Coins" }, function(coins)
		local player = Players.LocalPlayer
		if not player then return end
        player.PlayerGui.HUD.coins.coinsLabel.Text = "Coins: " .. coins
	end)
end

return HUDController
