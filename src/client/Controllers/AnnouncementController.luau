--!strict
--[[
	Shows an admin announcement (Net.announcement) to everyone, wherever they
	are: menu, round, killcam.

	It has its own screen (Screens.Announcement, authored in Studio, stacking)
	rather than borrowing the HUD's notice line, because the HUD is closed in
	the menu and a notice sent there is never seen. The screen is not one
	MenuController routes, so no phase change closes it; it closes itself
	after HOLD seconds, and a newer announcement replaces an older one and
	restarts the clock.

	The text was filtered by the server before it was sent (AdminService); this
	only displays it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local UIController = require(script.Parent.UIController)

local log = Log.new("AnnouncementController")

local player = Players.LocalPlayer

local SCREEN_NAME = "Announcement"
local HOLD = 6

local AnnouncementController = {}

-- Bumped per announcement, so an older close timer does nothing.
local generation = 0

local function findLabels(): (TextLabel?, TextLabel?)
	local playerGui = player:FindFirstChild("PlayerGui")
	local screens = if playerGui ~= nil then playerGui:FindFirstChild("Screens") else nil
	local screen = if screens ~= nil then screens:FindFirstChild(SCREEN_NAME, true) else nil
	local root = if screen ~= nil then screen:FindFirstChild("Root") else nil
	local banner = if root ~= nil then root:FindFirstChild("Banner") else nil
	if banner == nil then
		return nil, nil
	end
	local from = banner:FindFirstChild("FromLabel")
	local message = banner:FindFirstChild("MessageLabel")
	return if from ~= nil and from:IsA("TextLabel") then from else nil,
		if message ~= nil and message:IsA("TextLabel") then message else nil
end

local function show(message: string, from: string)
	local fromLabel, messageLabel = findLabels()
	if messageLabel == nil then
		log.warn(`no Screens.{SCREEN_NAME}.Root.Banner.MessageLabel -- announcement not shown: {message}`)
		return
	end
	messageLabel.Text = message
	if fromLabel ~= nil then
		fromLabel.Text = `ANNOUNCEMENT FROM {string.upper(from)}`
	end

	generation += 1
	local mine = generation
	UIController.open(SCREEN_NAME)
	task.delay(HOLD, function()
		if generation == mine and UIController.isOpen(SCREEN_NAME) then
			UIController.close(SCREEN_NAME)
		end
	end)
end

function AnnouncementController.Init()
	-- In Init: an announcement fired at a client with no listener is dropped.
	Net.announcement.listen(function(data)
		show(data.message, data.from)
	end)
end

function AnnouncementController.Start() end

return AnnouncementController
