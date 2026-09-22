--!strict
--[[
	The admin panel: find a player (in this server or not), edit their data,
	act on them, and control the round.

	Studio owns the screen (Screens.Admin) and the menu button
	(MainMenu.Root.AdminButton); this finds and drives them. It creates clones
	of the screen's authored templates and nothing else.

	NOTHING HERE IS AUTHORITY. Access comes from the server (Net.adminAccess)
	and only decides whether the button and the panel are shown; every request
	below is re-checked by AdminService, which also does all the validation.
	So this file never checks a value's range -- it sends what was typed and
	shows the server's answer (Net.adminResult) on the status line.

	The panel opens from the main menu button or M (F2 too), over whatever is
	on screen (it is not exclusive), and the same key closes it. Mid-round the
	player STAYS in first person: the camera is left alone, and the cursor is
	freed only because the panel's CloseButton is `Modal` (authored in
	Studio), which unlocks the mouse for exactly as long as the panel is
	enabled. The key is ignored while a TextBox has focus, so typing an "m"
	into the panel or the chat never closes it.
]]

local ContextActionService = game:GetService("ContextActionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Cosmetics = require(ReplicatedStorage.Shared.Cosmetics)
local Items = require(ReplicatedStorage.Shared.Items)
local Log = require(ReplicatedStorage.Shared.Log)
local MapCatalog = require(ReplicatedStorage.Shared.MapCatalog)
local Match = require(ReplicatedStorage.Shared.Match)
local MatchController = require(script.Parent.MatchController)
local Net = require(ReplicatedStorage.Shared.Net)
local UIController = require(script.Parent.UIController)

local log = Log.new("AdminController")

local player = Players.LocalPlayer

local SCREEN_NAME = "Admin"
local SCREEN_TIMEOUT = 10
local TOGGLE_ACTION = "AdminPanelToggle"
local TOGGLE_KEYS = { Enum.KeyCode.M, Enum.KeyCode.F2 }
-- How often the SERVER tab asks for the forced round and the log while open.
local STATE_REFRESH = 2
-- A second click on RESET within this many seconds confirms it.
local RESET_CONFIRM_WINDOW = 3

local OK_COLOR = Color3.fromRGB(120, 230, 150)
local ERROR_COLOR = Color3.fromRGB(255, 120, 120)
local MUTED_COLOR = Color3.fromRGB(140, 150, 168)
local ACCENT = Color3.fromRGB(0, 200, 255)
local CHOICE_IDLE = Color3.fromRGB(26, 30, 42)
local CHOICE_SELECTED = Color3.fromRGB(0, 110, 145)
local TAB_IDLE = Color3.fromRGB(44, 50, 66)

type Tab = "Players" | "Server" | "Log"

type Location = "Here" | "Elsewhere" | "Offline" | "None"

type Target = {
	userId: number,
	name: string,
	location: Location,
	data: any,
}

type Elements = {
	root: GuiObject,
	status: TextLabel,
	close: GuiButton,
	tabs: { [string]: GuiButton },
	pages: { [string]: GuiObject },
	-- Players page
	dropdown: GuiButton,
	dropdownLabel: TextLabel,
	dropdownList: ScrollingFrame,
	playerOptionTemplate: GuiButton,
	usernameBox: TextBox,
	loadButton: GuiButton,
	targetLabel: TextLabel,
	fields: { [string]: { box: TextBox, button: GuiButton } },
	-- One row per inventory item in the catalog, built from ItemRowTemplate.
	inventoryList: ScrollingFrame,
	itemRowTemplate: GuiObject,
	equippedLabel: TextLabel,
	titlesList: ScrollingFrame,
	titleToggleTemplate: GuiButton,
	pathBox: TextBox,
	pathValueBox: TextBox,
	pathSetButton: GuiButton,
	resetButton: GuiButton,
	resetLabel: TextLabel,
	actionButtons: { GuiButton },
	-- Built from the catalogs: one GIVE button per item, one per team.
	giveItems: GuiObject,
	teamButtons: GuiObject,
	actionButtonTemplate: GuiButton,
	kickReasonBox: TextBox,
	-- Server page
	roundLabel: TextLabel,
	nextLabel: TextLabel,
	serverButtons: { GuiButton },
	mapChoices: GuiObject,
	gameModeChoices: GuiObject,
	teamModeChoices: GuiObject,
	choiceTemplate: GuiButton,
	announceBox: TextBox,
	announceButton: GuiButton,
	-- Log page
	logList: ScrollingFrame,
	logRowTemplate: TextLabel,
}

local AdminController = {}

local allowed = false
local screen: Elements? = nil
local tab: Tab = "Players"
local target: Target? = nil
local resetArmedAt = 0
local lastLog: { string } = {}
-- itemId -> the count box on its inventory row.
local itemBoxes: { [string]: TextBox } = {}

-- The next-round picks on the SERVER tab; "" means "leave it to the vote".
local picks: { [string]: string } = { Map = "", GameMode = "", TeamMode = "" }
local choiceButtons: { [string]: { [string]: GuiButton } } = { Map = {}, GameMode = {}, TeamMode = {} }

local function setStatus(text: string, color: Color3)
	local ui = screen
	if ui ~= nil then
		ui.status.Text = text
		ui.status.TextColor3 = color
	end
end

local function labelOf(button: Instance): TextLabel?
	local label = button:FindFirstChild("Label")
	return if label ~= nil and label:IsA("TextLabel") then label else nil
end

local function clearClones(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

--========================================================================
-- PLAYERS TAB
--========================================================================

local LOCATION_TEXT: { [string]: string } = {
	Here = "IN THIS SERVER -- edits apply now",
	Elsewhere = "IN ANOTHER SERVER -- edits apply within seconds",
	Offline = "OFFLINE -- edits apply on their next join",
	None = "NO SAVED DATA",
}

local function paintTitles(ui: Elements)
	local data = if target ~= nil then target.data else nil
	local owned = if type(data) == "table" and type(data.Titles) == "table" then data.Titles else {}
	local equipped = if type(data) == "table" and type(data.EquippedTitle) == "string" then data.EquippedTitle else ""

	for _, child in ui.titlesList:GetChildren() do
		if not child:IsA("GuiButton") then
			continue
		end
		local title = Cosmetics.title(child.Name)
		local label = labelOf(child)
		local equip = child:FindFirstChild("EquipButton")
		if title == nil or label == nil then
			continue
		end
		local isOwned = owned[title.Id] == true
		local rarity = Cosmetics.rarity(title.Rarity)
		label.Text = `{if title.Id == equipped then "★ " else ""}{title.Text}`
		label.TextColor3 = if isOwned and rarity ~= nil then rarity.Color else MUTED_COLOR
		child.BackgroundColor3 = if isOwned then CHOICE_SELECTED else CHOICE_IDLE
		if equip ~= nil and equip:IsA("GuiObject") then
			equip.Visible = isOwned
		end
	end
end

local function paintTarget()
	local ui = screen
	if ui == nil then
		return
	end
	local current = target
	if current == nil then
		ui.targetLabel.Text = "No player loaded -- pick one from the list or type a name"
		ui.targetLabel.TextColor3 = MUTED_COLOR
		for _, field in ui.fields do
			field.box.Text = ""
		end
		for _, box in itemBoxes do
			box.Text = ""
		end
		ui.equippedLabel.Text = ""
		paintTitles(ui)
		return
	end

	ui.targetLabel.Text = `{current.name} ({current.userId})  ·  {LOCATION_TEXT[current.location] or current.location}`
	ui.targetLabel.TextColor3 = if current.location == "None" then ERROR_COLOR else ACCENT

	local data = current.data
	local function show(key: string, value: any)
		local field = ui.fields[key]
		if field ~= nil then
			field.box.Text = if value ~= nil then tostring(value) else ""
		end
	end
	if type(data) == "table" then
		show("Cash", data.Cash)
		show("Level", data.Level)
		show("Experience", data.Experience)
		local inventory = if type(data.Inventory) == "table" then data.Inventory else {}
		for itemId, box in itemBoxes do
			local count = inventory[itemId]
			box.Text = tostring(if type(count) == "number" then count else 0)
		end
		local equipped = Cosmetics.title(data.EquippedTitle)
		ui.equippedLabel.Text = `Equipped title: {if equipped ~= nil then equipped.Text else "none"}`
	end
	paintTitles(ui)
end

local function lookup(query: string)
	if query == "" then
		return
	end
	setStatus(`Loading {query}...`, MUTED_COLOR)
	Net.adminLookup.send({ query = query })
end

local function edit(op: string, key: string, value: string)
	local current = target
	if current == nil or current.location == "None" then
		setStatus("Load a player first", ERROR_COLOR)
		return
	end
	Net.adminEdit.send({ userId = current.userId, op = op, key = key, value = value })
end

local function playerAction(action: string, arg: string)
	local current = target
	if current == nil then
		setStatus("Load a player first", ERROR_COLOR)
		return
	end
	if current.location ~= "Here" then
		setStatus("Player actions only work on someone in this server", ERROR_COLOR)
		return
	end
	Net.adminPlayerAction.send({ userId = current.userId, action = action, arg = arg })
end

local function buildDropdown(ui: Elements)
	clearClones(ui.dropdownList)
	for index, other in Players:GetPlayers() do
		local option = ui.playerOptionTemplate:Clone() :: GuiButton
		local label = labelOf(option)
		if label ~= nil then
			label.Text = `{other.DisplayName}  (@{other.Name})`
		end
		option.Name = tostring(other.UserId)
		option.LayoutOrder = index
		option.Visible = true
		local userId = other.UserId
		option.Activated:Connect(function()
			ui.dropdownList.Visible = false
			lookup(tostring(userId))
		end)
		option.Parent = ui.dropdownList
	end
end

--[[
	Every item the profile's Inventory can hold, one row each, straight from
	the catalog -- so a new case (or any future inventory item added to that
	list) shows up here with no change to this file or the screen. Each row
	sets the player's count of that item.
]]
local function buildInventoryRows(ui: Elements)
	clearClones(ui.inventoryList)
	table.clear(itemBoxes)
	for index, case in Cosmetics.CASES do
		local row = ui.itemRowTemplate:Clone() :: GuiObject
		local nameLabel = row:FindFirstChild("NameLabel")
		local box = row:FindFirstChild("Box")
		local setButton = row:FindFirstChild("SetButton")
		if
			nameLabel == nil
			or not nameLabel:IsA("TextLabel")
			or box == nil
			or not box:IsA("TextBox")
			or setButton == nil
			or not setButton:IsA("GuiButton")
		then
			row:Destroy()
			log.warn("ItemRowTemplate needs NameLabel, Box and SetButton")
			return
		end
		nameLabel.Text = case.DisplayName
		local itemId = case.Id
		local countBox: TextBox = box
		setButton.Activated:Connect(function()
			edit("SetCases", itemId, countBox.Text)
		end)
		row.Name = itemId
		row.LayoutOrder = index
		row.Visible = true
		row.Parent = ui.inventoryList
		itemBoxes[itemId] = countBox
	end
end

--[[
	The GIVE and TEAM buttons, from the catalogs: a new throwable in Items or a
	new team in Match gets its button here with no change to the screen.
]]
local function buildCatalogButtons(ui: Elements)
	local function add(container: GuiObject, index: number, text: string, color: Color3?, action: string, arg: string)
		local button = ui.actionButtonTemplate:Clone() :: GuiButton
		local label = labelOf(button)
		if label ~= nil then
			label.Text = text
			if color ~= nil then
				label.TextColor3 = color
			end
		end
		button.Name = arg
		button.LayoutOrder = index
		button.Visible = true
		button.Activated:Connect(function()
			playerAction(action, arg)
		end)
		button.Parent = container
	end

	clearClones(ui.giveItems)
	for index, item in Items.LIST do
		add(ui.giveItems, index, item.DisplayName, item.Color, "GiveItem", item.Id)
	end

	clearClones(ui.teamButtons)
	for index, teamId in Match.TEAM_ORDER do
		local team = Match.TEAMS[teamId]
		add(ui.teamButtons, index, team.DisplayName, team.Color, "SetTeam", teamId)
	end
end

local function buildTitleToggles(ui: Elements)
	clearClones(ui.titlesList)
	for index, title in Cosmetics.TITLES do
		local toggle = ui.titleToggleTemplate:Clone() :: GuiButton
		toggle.Name = title.Id
		toggle.LayoutOrder = index
		toggle.Visible = true
		local titleId = title.Id
		toggle.Activated:Connect(function()
			local current = target
			local data = if current ~= nil then current.data else nil
			local owned = type(data) == "table" and type(data.Titles) == "table" and data.Titles[titleId] == true
			edit(if owned then "RevokeTitle" else "GrantTitle", titleId, "")
		end)
		local equip = toggle:FindFirstChild("EquipButton")
		if equip ~= nil and equip:IsA("GuiButton") then
			equip.Activated:Connect(function()
				local current = target
				local data = if current ~= nil then current.data else nil
				local equipped = type(data) == "table" and data.EquippedTitle == titleId
				edit("EquipTitle", if equipped then "" else titleId, "")
			end)
		end
		toggle.Parent = ui.titlesList
	end
	paintTitles(ui)
end

--========================================================================
-- SERVER TAB
--========================================================================

local function paintChoices()
	for group, buttons in choiceButtons do
		for id, button in buttons do
			button.BackgroundColor3 = if picks[group] == id then CHOICE_SELECTED else CHOICE_IDLE
		end
	end
end

local function buildChoices(
	ui: Elements,
	group: string,
	container: GuiObject,
	options: { { id: string, text: string } }
)
	clearClones(container)
	table.clear(choiceButtons[group])
	for index, option in options do
		local button = ui.choiceTemplate:Clone() :: GuiButton
		local label = labelOf(button)
		if label ~= nil then
			label.Text = option.text
		end
		button.Name = if option.id == "" then "Vote" else option.id
		button.LayoutOrder = index
		button.Visible = true
		local id = option.id
		button.Activated:Connect(function()
			picks[group] = id
			paintChoices()
		end)
		button.Parent = container
		choiceButtons[group][id] = button
	end
	paintChoices()
end

local function buildAllChoices(ui: Elements)
	local maps = { { id = "", text = "VOTE" } }
	for _, map in MapCatalog.LIST do
		table.insert(maps, { id = map.Id, text = map.DisplayName })
	end
	buildChoices(ui, "Map", ui.mapChoices, maps)

	local gameModes = { { id = "", text = "VOTE" } }
	for _, id in Match.GAME_MODE_ORDER do
		table.insert(gameModes, { id = id, text = Match.GAME_MODES[id].DisplayName })
	end
	buildChoices(ui, "GameMode", ui.gameModeChoices, gameModes)

	local teamModes = { { id = "", text = "VOTE" } }
	for _, id in Match.TEAM_MODE_ORDER do
		table.insert(teamModes, { id = id, text = Match.TEAM_MODES[id].DisplayName })
	end
	buildChoices(ui, "TeamMode", ui.teamModeChoices, teamModes)
end

local function paintRound()
	local ui = screen
	if ui == nil then
		return
	end
	local round = MatchController.getRound()
	local mapId = if round ~= nil then round.MapId else ""
	local map = MapCatalog.byId(mapId)
	local seconds = math.max(0, math.floor(MatchController.secondsRemaining()))
	ui.roundLabel.Text =
		`{MatchController.getState()}  ·  {if map ~= nil then map.DisplayName else "no map"}  ·  {Match.GAME_MODES[MatchController.getGameModeId()].DisplayName}  ·  {MatchController.getTeamMode().DisplayName}  ·  {string.format(
			"%d:%02d",
			seconds // 60,
			seconds % 60
		)} left`
end

local function paintLog()
	local ui = screen
	if ui == nil then
		return
	end
	clearClones(ui.logList)
	for index, line in lastLog do
		local row = ui.logRowTemplate:Clone() :: TextLabel
		row.Text = line
		row.LayoutOrder = index
		row.Visible = true
		row.Parent = ui.logList
	end
end

--========================================================================
-- TABS, OPEN / CLOSE
--========================================================================

local function showTab(which: Tab)
	tab = which
	local ui = screen
	if ui == nil then
		return
	end
	for name, page in ui.pages do
		page.Visible = name == which
	end
	for name, button in ui.tabs do
		local bar = button:FindFirstChild("SelectedBar")
		if bar ~= nil and bar:IsA("GuiObject") then
			bar.BackgroundColor3 = if name == which then ACCENT else TAB_IDLE
		end
	end
	if which ~= "Players" then
		Net.adminRequestState.send()
	end
end

local function open()
	if not allowed or screen == nil then
		return
	end
	UIController.open(SCREEN_NAME)
end

local function close()
	UIController.close(SCREEN_NAME)
end

local function onOpened()
	-- No camera override: the player stays in first person. The cursor is
	-- freed by the Modal CloseButton for as long as the panel is enabled.
	showTab(tab)
	paintRound()
	task.spawn(function()
		while UIController.isOpen(SCREEN_NAME) do
			paintRound()
			if tab ~= "Players" then
				Net.adminRequestState.send()
			end
			task.wait(STATE_REFRESH)
		end
	end)
end

local function onClosed()
	local ui = screen
	if ui ~= nil then
		ui.dropdownList.Visible = false
	end
end

--========================================================================
-- BINDING
--========================================================================

local function resolve(gui: Instance): Elements?
	local root = gui:FindFirstChild("Root")
	if root == nil or not root:IsA("GuiObject") then
		log.warn(`{SCREEN_NAME} has no Root -- the admin panel will not be drawn`)
		return nil
	end

	local missing: { string } = {}
	local function grab(path: string, className: string): any
		local current: Instance? = root
		for segment in string.gmatch(path, "[^%.]+") do
			if current == nil then
				break
			end
			current = current:FindFirstChild(segment)
		end
		if current == nil or not current:IsA(className) then
			table.insert(missing, path)
			return nil
		end
		return current
	end

	local fields: { [string]: { box: TextBox, button: GuiButton } } = {}
	for _, name in { "Cash", "Level", "Experience" } do
		local box = grab(`Panel.PlayersPage.Data.{name}Row.Box`, "TextBox")
		local button = grab(`Panel.PlayersPage.Data.{name}Row.SetButton`, "GuiButton")
		if box ~= nil and button ~= nil then
			fields[name] = { box = box, button = button }
		end
	end

	local actionButtons: { GuiButton } = {}
	local actionsFolder = grab("Panel.PlayersPage.Actions", "GuiObject")
	if actionsFolder ~= nil then
		for _, descendant in actionsFolder:GetDescendants() do
			if descendant:IsA("GuiButton") and descendant:GetAttribute("Action") ~= nil then
				table.insert(actionButtons, descendant)
			end
		end
	end

	local serverButtons: { GuiButton } = {}
	local serverPage = grab("Panel.ServerPage", "GuiObject")
	if serverPage ~= nil then
		for _, descendant in serverPage:GetDescendants() do
			if descendant:IsA("GuiButton") and descendant:GetAttribute("ServerAction") ~= nil then
				table.insert(serverButtons, descendant)
			end
		end
	end

	local ui: Elements = {
		root = root,
		status = grab("Panel.StatusLabel", "TextLabel"),
		close = grab("Panel.Header.CloseButton", "GuiButton"),
		tabs = {
			Players = grab("Panel.Tabs.PlayersTab", "GuiButton"),
			Server = grab("Panel.Tabs.ServerTab", "GuiButton"),
			Log = grab("Panel.Tabs.LogTab", "GuiButton"),
		},
		pages = {
			Players = grab("Panel.PlayersPage", "GuiObject"),
			Server = serverPage,
			Log = grab("Panel.LogPage", "GuiObject"),
		},
		dropdown = grab("Panel.PlayersPage.TargetBar.PlayerDropdown", "GuiButton"),
		dropdownLabel = grab("Panel.PlayersPage.TargetBar.PlayerDropdown.Label", "TextLabel"),
		dropdownList = grab("Panel.PlayersPage.DropdownList", "ScrollingFrame"),
		playerOptionTemplate = grab("Panel.PlayersPage.PlayerOptionTemplate", "GuiButton"),
		usernameBox = grab("Panel.PlayersPage.TargetBar.UsernameBox", "TextBox"),
		loadButton = grab("Panel.PlayersPage.TargetBar.LoadButton", "GuiButton"),
		targetLabel = grab("Panel.PlayersPage.TargetLabel", "TextLabel"),
		fields = fields,
		inventoryList = grab("Panel.PlayersPage.Data.InventoryList", "ScrollingFrame"),
		itemRowTemplate = grab("Panel.PlayersPage.ItemRowTemplate", "GuiObject"),
		equippedLabel = grab("Panel.PlayersPage.Data.EquippedLabel", "TextLabel"),
		titlesList = grab("Panel.PlayersPage.Data.TitlesList", "ScrollingFrame"),
		titleToggleTemplate = grab("Panel.PlayersPage.TitleToggleTemplate", "GuiButton"),
		pathBox = grab("Panel.PlayersPage.Data.FieldRow.PathBox", "TextBox"),
		pathValueBox = grab("Panel.PlayersPage.Data.FieldRow.ValueBox", "TextBox"),
		pathSetButton = grab("Panel.PlayersPage.Data.FieldRow.SetButton", "GuiButton"),
		resetButton = grab("Panel.PlayersPage.Data.ResetButton", "GuiButton"),
		resetLabel = grab("Panel.PlayersPage.Data.ResetButton.Label", "TextLabel"),
		actionButtons = actionButtons,
		giveItems = grab("Panel.PlayersPage.Actions.GiveItems", "GuiObject"),
		teamButtons = grab("Panel.PlayersPage.Actions.Teams", "GuiObject"),
		actionButtonTemplate = grab("Panel.PlayersPage.ActionButtonTemplate", "GuiButton"),
		kickReasonBox = grab("Panel.PlayersPage.Actions.KickRow.ReasonBox", "TextBox"),
		roundLabel = grab("Panel.ServerPage.RoundLabel", "TextLabel"),
		nextLabel = grab("Panel.ServerPage.NextLabel", "TextLabel"),
		serverButtons = serverButtons,
		mapChoices = grab("Panel.ServerPage.MapChoices", "GuiObject"),
		gameModeChoices = grab("Panel.ServerPage.GameModeChoices", "GuiObject"),
		teamModeChoices = grab("Panel.ServerPage.TeamModeChoices", "GuiObject"),
		choiceTemplate = grab("Panel.ServerPage.ChoiceTemplate", "GuiButton"),
		announceBox = grab("Panel.ServerPage.AnnounceRow.AnnounceBox", "TextBox"),
		announceButton = grab("Panel.ServerPage.AnnounceRow.AnnounceButton", "GuiButton"),
		logList = grab("Panel.LogPage.LogList", "ScrollingFrame"),
		logRowTemplate = grab("Panel.LogPage.LogRowTemplate", "TextLabel"),
	}

	if #missing > 0 then
		log.warn(`Admin screen is missing {table.concat(missing, ", ")} -- the panel will not be drawn`)
		return nil
	end

	ui.playerOptionTemplate.Visible = false
	ui.actionButtonTemplate.Visible = false
	ui.itemRowTemplate.Visible = false
	ui.titleToggleTemplate.Visible = false
	ui.choiceTemplate.Visible = false
	ui.logRowTemplate.Visible = false
	ui.dropdownList.Visible = false
	return ui
end

local function bind(ui: Elements)
	ui.close.Activated:Connect(close)
	for name, button in ui.tabs do
		button.Activated:Connect(function()
			showTab(name :: Tab)
		end)
	end

	-- Choosing a target.
	ui.dropdown.Activated:Connect(function()
		local showing = not ui.dropdownList.Visible
		if showing then
			buildDropdown(ui)
		end
		ui.dropdownList.Visible = showing
	end)
	ui.loadButton.Activated:Connect(function()
		lookup(ui.usernameBox.Text)
	end)
	ui.usernameBox.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			lookup(ui.usernameBox.Text)
		end
	end)

	-- Data edits.
	local FIELD_OPS: { [string]: string } = {
		Cash = "SetCash",
		Level = "SetLevel",
		Experience = "SetExperience",
	}
	for name, field in ui.fields do
		local op = FIELD_OPS[name]
		field.button.Activated:Connect(function()
			edit(op, "", field.box.Text)
		end)
	end
	ui.pathSetButton.Activated:Connect(function()
		edit("SetField", ui.pathBox.Text, ui.pathValueBox.Text)
	end)
	ui.resetButton.Activated:Connect(function()
		local now = os.clock()
		if now - resetArmedAt <= RESET_CONFIRM_WINDOW then
			resetArmedAt = 0
			ui.resetLabel.Text = "RESET DATA"
			edit("ResetData", "", "")
			return
		end
		resetArmedAt = now
		ui.resetLabel.Text = "CLICK AGAIN TO CONFIRM"
		task.delay(RESET_CONFIRM_WINDOW, function()
			if resetArmedAt == now then
				resetArmedAt = 0
				ui.resetLabel.Text = "RESET DATA"
			end
		end)
	end)

	-- Player actions: each authored button carries its action (and argument)
	-- as attributes, so a new button needs no code.
	for _, button in ui.actionButtons do
		button.Activated:Connect(function()
			local action = button:GetAttribute("Action")
			local arg = button:GetAttribute("Arg")
			if type(action) ~= "string" then
				return
			end
			if action == "Kick" then
				playerAction(action, ui.kickReasonBox.Text)
			else
				playerAction(action, if type(arg) == "string" then arg else "")
			end
		end)
	end

	-- Server actions, the same way.
	for _, button in ui.serverButtons do
		button.Activated:Connect(function()
			local action = button:GetAttribute("ServerAction")
			if type(action) ~= "string" then
				return
			end
			if action == "SetNext" or action == "ChangeNow" then
				Net.adminServerAction.send({ action = action, a = picks.Map, b = picks.GameMode, c = picks.TeamMode })
			else
				Net.adminServerAction.send({ action = action, a = "", b = "", c = "" })
			end
		end)
	end
	ui.announceButton.Activated:Connect(function()
		Net.adminServerAction.send({ action = "Announce", a = ui.announceBox.Text, b = "", c = "" })
		ui.announceBox.Text = ""
	end)

	buildInventoryRows(ui)
	buildCatalogButtons(ui)
	buildTitleToggles(ui)
	buildAllChoices(ui)
	paintTarget()
	paintLog()
	showTab(tab)
end

-- The menu button, shown only to admins. Re-found after every PlayerGui
-- re-clone, like the panel.
local function bindMenuButton(screens: Instance)
	local mainMenu = screens:FindFirstChild("MainMenu", true)
	local root = if mainMenu ~= nil then mainMenu:FindFirstChild("Root") else nil
	local button = if root ~= nil then root:FindFirstChild("AdminButton") else nil
	if button == nil or not button:IsA("GuiButton") then
		return
	end
	button.Visible = allowed
	button.Activated:Connect(open)
end

local function attachLoop()
	local playerGui = player:WaitForChild("PlayerGui")
	while true do
		local screensFolder = playerGui:WaitForChild("Screens", SCREEN_TIMEOUT)
		if screensFolder == nil then
			return
		end
		local gui = screensFolder:WaitForChild(SCREEN_NAME, SCREEN_TIMEOUT)
		if gui == nil then
			log.info(`no Screens.{SCREEN_NAME} authored -- nothing to drive`)
			return
		end

		local ui = resolve(gui)
		screen = ui
		if ui ~= nil then
			bind(ui)
		end
		bindMenuButton(screensFolder)

		screensFolder.Destroying:Wait()
		screen = nil
		while playerGui:FindFirstChild("Screens") == screensFolder do
			playerGui.ChildRemoved:Wait()
		end
	end
end

local function setAccess(value: boolean)
	allowed = value
	local folder = UIController.getScreensFolder()
	if folder ~= nil then
		local mainMenu = folder:FindFirstChild("MainMenu", true)
		local root = if mainMenu ~= nil then mainMenu:FindFirstChild("Root") else nil
		local button = if root ~= nil then root:FindFirstChild("AdminButton") else nil
		if button ~= nil and button:IsA("GuiObject") then
			button.Visible = value
		end
	end
	if not value and UIController.isOpen(SCREEN_NAME) then
		close()
	end
end

function AdminController.Init()
	-- In Init: a packet fired at a client with no listener yet is dropped.
	Net.adminAccess.listen(function(data)
		setAccess(data.allowed)
	end)

	Net.adminProfile.listen(function(data)
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, data.data)
		target = {
			userId = data.userId,
			name = data.name,
			location = data.location :: Location,
			data = if ok then decoded else {},
		}
		setStatus(
			if data.location == "None" then "That player has no saved data" else `Loaded {data.name}`,
			if data.location == "None" then ERROR_COLOR else OK_COLOR
		)
		paintTarget()
	end)

	Net.adminResult.listen(function(data)
		setStatus(data.message, if data.ok then OK_COLOR else ERROR_COLOR)
	end)

	Net.adminState.listen(function(data)
		local ui = screen
		if ui ~= nil then
			local function part(value: string, fallback: string): string
				return if value ~= "" then value else fallback
			end
			local forced = data.nextMap ~= "" or data.nextGameMode ~= "" or data.nextTeamMode ~= ""
			ui.nextLabel.Text = if forced
				then `Next round: {part(data.nextMap, "vote")} / {part(data.nextGameMode, "vote")} / {part(
					data.nextTeamMode,
					"vote"
				)}{if data.nextSkipVote then " (no vote)" else ""}`
				else "Next round: decided by the vote"
		end
		lastLog = data.log
		paintLog()
	end)
end

function AdminController.Start()
	UIController.onOpen(SCREEN_NAME, onOpened)
	UIController.onClose(SCREEN_NAME, onClosed)

	ContextActionService:BindAction(TOGGLE_ACTION, function(_, state: Enum.UserInputState)
		if state ~= Enum.UserInputState.Begin or not allowed then
			return Enum.ContextActionResult.Pass
		end
		-- An "m" typed into a TextBox (the panel's own fields, the chat) is
		-- text, not the shortcut.
		if UserInputService:GetFocusedTextBox() ~= nil then
			return Enum.ContextActionResult.Pass
		end
		if UIController.isOpen(SCREEN_NAME) then
			close()
		else
			open()
		end
		return Enum.ContextActionResult.Sink
	end, false, table.unpack(TOGGLE_KEYS))

	-- Ask, rather than only wait to be told: the server's push on join can
	-- beat this client's listeners (Net.adminRequestAccess).
	Net.adminRequestAccess.send()

	attachLoop()
end

return AdminController
