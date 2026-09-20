--!strict
--[[
	Keeps the on-screen HUD in sync with replicated player data.

	Also the worked example of the two rules that matter most on the client:

	  1. Author the ScreenGui in Studio, find it here. Rojo mounts scripts, not
	     instances -- StarterGui is yours (ARCHITECTURE.md, "The map"), so this
	     controller never builds the GUI, it only drives one that already exists.
	  2. Read state through DataController.observe, never off a remote. observe
	     fires once with the current value AND again on every change, so there is
	     no separate "populate on join" path to forget
	     (NETWORKING-AND-DATA.md, "which pipe?").

	Nothing here is required: with no HUD authored yet, this logs once and stays
	idle rather than erroring on every Coins change.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataController = require(script.Parent.DataController)
local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("HUDController")

local player = Players.LocalPlayer

-- How long to wait for the authored HUD before deciding there isn't one.
-- Bounded so a missing GUI surfaces as one warning instead of hanging Start().
local HUD_TIMEOUT = 10

local HUDController = {}

function HUDController.Init()
	-- Replica.OnNew and other "must exist before data arrives" listeners go HERE.
	-- Main.client.luau calls Replica.RequestData() only after every Init() has run.
end

function HUDController.Start()
	local playerGui = player:WaitForChild("PlayerGui")

	-- WaitForChild, not a direct index: PlayerGui is populated by replication
	-- from StarterGui, so the HUD is reliably absent for the first frames even
	-- when it HAS been authored. A direct index is a race that happens to pass
	-- on a fast machine.
	local hud = playerGui:WaitForChild("HUD", HUD_TIMEOUT)
	if hud == nil then
		log.info("no StarterGui.HUD authored yet -- nothing to drive")
		return
	end

	local coinsLabel = hud:FindFirstChild("coinsLabel", true)
	if coinsLabel == nil or not coinsLabel:IsA("TextLabel") then
		log.warn("HUD is present but has no coinsLabel TextLabel -- coins will not display")
		return
	end

	-- Fires immediately with the current value, then on every change. A late
	-- joiner and a mid-session change take the exact same path.
	DataController.observe({ "Coins" }, function(coins)
		coinsLabel.Text = `Coins: {coins}`
	end)
end

return HUDController
