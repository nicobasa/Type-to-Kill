--!strict
--[[
	Opens a UI screen when a ProximityPrompt is triggered.

	Opt-in is a `Screen` string attribute on the prompt itself, naming a screen
	UIController knows about (see UIController.luau) -- not a CollectionService
	tag. A single PromptTriggered connection covers every prompt in the game,
	present now or streamed in later, with nothing to bind or unbind per
	instance.

	Authored in Studio, read here:

		Screen   string, the screen to open on trigger. Absent = not a UI
		         prompt, ignored entirely.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local UIController = require(script.Parent.UIController)

local log = Log.new("PromptController")

local player = Players.LocalPlayer

local PromptController = {}

local function onPromptTriggered(prompt: ProximityPrompt, playerWhoTriggered: Player)
	if playerWhoTriggered ~= player then
		-- PromptTriggered is detected from local input before the server ever
		-- hears about it, so on the client it only ever fires for the
		-- LocalPlayer's own trigger -- this never fires for another player. Kept
		-- as a guard rather than an assumption: it is free either way.
		return
	end

	-- Read live, not cached at bind time -- there is nothing to cache per-prompt
	-- in the first place with a single shared connection, and it means
	-- retuning Screen in the property panel mid-playtest just works.
	local screen = prompt:GetAttribute("Screen")
	if screen == nil then
		return
	end
	if type(screen) ~= "string" then
		log.warn(`{prompt:GetFullName()}.Screen should be a string, got {typeof(screen)} -- ignoring`)
		return
	end

	UIController.toggle(screen)
end

function PromptController.Init()
	-- A player cannot trigger a prompt before their character exists, so the
	-- PlayerGui-population race UIController.Init works around does not apply
	-- here: by the time any trigger fires, UIController has long since
	-- registered whatever screens exist.
	ProximityPromptService.PromptTriggered:Connect(onPromptTriggered)
end

return PromptController
