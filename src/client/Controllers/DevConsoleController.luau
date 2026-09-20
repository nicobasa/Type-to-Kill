--!strict
--[[
	The developer console. Built only when the server tells us we're a developer
	(Net.devAccess) -- see Services/DevService.luau, which owns that list and
	performs the server-side re-check that actually matters.

	Deliberately breaks UI-AND-MOTION.md's "Studio owns the GUIs" rule: this UI
	is built here, in code, rather than authored under StarterGui.Screens.
	Three reasons:

	  (a) A dev tool must not sit in StarterGui, which replicates to every
	      player whether or not they'll ever be allowed to open it.
	  (b) It must not be one of UIController's exclusive screens -- opening it
	      would close whatever the player actually has open (their HUD, a
	      menu), since UIController.open() closes other exclusive screens by
	      design.
	  (c) It should be versioned in git like the rest of the game, not
	      hand-authored in a Studio place file nobody diffs.

	Hiding the UI is NOT the security control. Rojo has no concept of "ship
	this script to some players" -- every client downloads this LocalScript
	regardless, so a non-developer could still fire Net.devSet by hand without
	ever seeing this icon. The only real gate is the re-check DevService does on
	every packet. The devAccess packet exists so non-developers don't pay for a
	UI they can never use, not to keep anyone out -- which is also why it is
	safe for the server to simply tell us the answer.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Icon = require(ReplicatedStorage.Packages.TopbarPlus)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("DevConsoleController")

local REFRESH_INTERVAL = 2

local BACKGROUND_COLOR = Color3.fromRGB(24, 24, 28)
local FIELD_COLOR = Color3.fromRGB(40, 40, 46)
local TEXT_COLOR = Color3.fromRGB(225, 225, 230)
local MUTED_TEXT_COLOR = Color3.fromRGB(170, 170, 178)
local OK_COLOR = Color3.fromRGB(90, 210, 130)
local ERROR_COLOR = Color3.fromRGB(230, 90, 90)

type SnapshotEntry = {
	path: { string },
	kind: string,
	value: string,
}

type Row = {
	frame: Frame,
	valueBox: TextBox,
	path: { string },
	kind: string,
}

local player = Players.LocalPlayer

-- Populated by Init()'s listeners; read and written by Start()'s UI, which
-- may not exist yet when a packet first arrives -- every UI touch below goes
-- through a nil-guarded helper rather than assuming these are non-nil.
local screenGui: ScreenGui? = nil
local targetButton: TextButton? = nil
local targetListFrame: ScrollingFrame? = nil
local bodyScroll: ScrollingFrame? = nil
local statusLabel: TextLabel? = nil
local newKeyPathBox: TextBox? = nil
local newKeyValueBox: TextBox? = nil
local icon: any = nil

local rows: { [string]: Row } = {}
local latestEntries: { SnapshotEntry } = {}
local currentTargetUserId = player.UserId
local currentTargetName = player.Name
local targetListVisible = false
local refreshThread: thread? = nil

local function dottedPath(path: { string }): string
	return table.concat(path, ".")
end

local function requestSnapshot()
	Net.devRequestSnapshot.send({ targetUserId = currentTargetUserId })
end

local function applyResult(data: { ok: boolean, message: string })
	local label = statusLabel
	if label == nil then
		return
	end
	label.Text = data.message
	label.TextColor3 = if data.ok then OK_COLOR else ERROR_COLOR
end

local function stopRefreshLoop()
	if refreshThread ~= nil then
		task.cancel(refreshThread)
		refreshThread = nil
	end
end

-- Only while the panel is open, per spec -- cancelled on close and on
-- destroy so it can never outlive the UI it's refreshing.
local function startRefreshLoop()
	stopRefreshLoop()
	refreshThread = task.spawn(function()
		while true do
			task.wait(REFRESH_INTERVAL)
			requestSnapshot()
		end
	end)
end

local function open()
	local gui = screenGui
	if gui == nil then
		return
	end
	gui.Enabled = true
	requestSnapshot()
	startRefreshLoop()
end

local function close()
	local gui = screenGui
	if gui == nil then
		return
	end
	gui.Enabled = false
	stopRefreshLoop()
end

local function commitRow(row: Row, box: TextBox)
	Net.devSet.send({
		targetUserId = currentTargetUserId,
		path = row.path,
		kind = row.kind,
		value = box.Text,
	})
end

local function createRow(entry: SnapshotEntry, layoutOrder: number, parent: ScrollingFrame): Row
	local frame = Instance.new("Frame")
	frame.Name = dottedPath(entry.path)
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, 26)
	frame.LayoutOrder = layoutOrder

	local label = Instance.new("TextLabel")
	label.Name = "PathLabel"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(0.55, -4, 1, 0)
	label.Font = Enum.Font.Gotham
	label.TextSize = 13
	label.TextColor3 = MUTED_TEXT_COLOR
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Text = dottedPath(entry.path)
	label.Parent = frame

	local box = Instance.new("TextBox")
	box.Name = "ValueBox"
	box.Position = UDim2.new(0.55, 4, 0, 0)
	box.Size = UDim2.new(0.45, -4, 1, 0)
	box.BackgroundColor3 = FIELD_COLOR
	box.TextColor3 = TEXT_COLOR
	box.Font = Enum.Font.Gotham
	box.TextSize = 13
	box.ClearTextOnFocus = false
	box.Text = entry.value
	box.Parent = frame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = box

	local row: Row = { frame = frame, valueBox = box, path = entry.path, kind = entry.kind }

	box.FocusLost:Connect(function(enterPressed: boolean)
		if not enterPressed then
			return
		end
		commitRow(row, box)
	end)

	frame.Parent = parent
	return row
end

--[[
	Rebuilds from `latestEntries`, reusing existing row instances keyed by
	dotted path rather than destroying and recreating everything. That's what
	makes the "don't stomp a focused box" rule below possible: a full
	destroy/recreate would blow away the TextBox the player is mid-edit in,
	which is exactly the poll-fights-the-typist bug this has to avoid.
]]
local function rebuildRows()
	local body = bodyScroll
	if body == nil then
		return
	end

	local seen: { [string]: boolean } = {}

	for index, entry in latestEntries do
		local key = dottedPath(entry.path)
		seen[key] = true

		local row = rows[key]
		if row == nil then
			row = createRow(entry, index, body)
			rows[key] = row
		else
			row.frame.LayoutOrder = index
			row.path = entry.path
			row.kind = entry.kind
			if not row.valueBox:IsFocused() then
				row.valueBox.Text = entry.value
			end
		end
	end

	for key, row in rows do
		if not seen[key] then
			row.frame:Destroy()
			rows[key] = nil
		end
	end
end

local function setTarget(newTarget: Player)
	currentTargetUserId = newTarget.UserId
	currentTargetName = newTarget.Name

	local button = targetButton
	if button ~= nil then
		button.Text = `Target: {currentTargetName}`
	end

	-- Clear immediately rather than waiting for the fresh snapshot -- showing
	-- the OLD target's rows under the NEW target's label for even one frame
	-- is exactly the kind of mixup a god-mode console can't afford.
	for key, row in rows do
		row.frame:Destroy()
		rows[key] = nil
	end
	latestEntries = {}

	requestSnapshot()
end

local function closeTargetList()
	local list = targetListFrame
	if list == nil then
		return
	end
	list.Visible = false
	targetListVisible = false
end

-- Rebuilt fresh every open -- a cached roster would go stale the moment
-- anyone joins or leaves while the panel is up.
local function openTargetList()
	local list = targetListFrame
	if list == nil then
		return
	end

	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	for index, candidate in Players:GetPlayers() do
		local button = Instance.new("TextButton")
		button.Name = candidate.Name
		button.LayoutOrder = index
		button.Size = UDim2.new(1, 0, 0, 26)
		button.BackgroundColor3 = FIELD_COLOR
		button.TextColor3 = TEXT_COLOR
		button.Font = Enum.Font.Gotham
		button.TextSize = 13
		button.Text = candidate.Name
		button.Parent = list

		button.Activated:Connect(function()
			setTarget(candidate)
			closeTargetList()
		end)
	end

	list.Visible = true
	targetListVisible = true
end

-- Dotted entry means a key containing a literal "." can't be created here --
-- an accepted limit of a text affordance, not something worth a richer
-- parser for.
local function inferKind(raw: string): string
	if tonumber(raw) ~= nil then
		return "number"
	elseif raw == "true" or raw == "false" then
		return "boolean"
	end
	return "string"
end

local function onCreateClicked()
	local pathBox = newKeyPathBox
	local valueBox = newKeyValueBox
	if pathBox == nil or valueBox == nil then
		return
	end

	local pathText = pathBox.Text
	if pathText == "" then
		return
	end

	Net.devSet.send({
		targetUserId = currentTargetUserId,
		path = string.split(pathText, "."),
		kind = inferKind(valueBox.Text),
		value = valueBox.Text,
	})
end

local function cleanup()
	stopRefreshLoop()
	local topbarIcon = icon
	if topbarIcon ~= nil then
		topbarIcon:destroy()
		icon = nil
	end
end

local function withCorner(instance: GuiObject, radius: number): GuiObject
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = instance
	return instance
end

local function newButton(text: string, size: UDim2): TextButton
	local button = Instance.new("TextButton")
	button.Font = Enum.Font.Gotham
	button.TextSize = 14
	button.TextColor3 = TEXT_COLOR
	button.BackgroundColor3 = FIELD_COLOR
	button.Size = size
	button.Text = text
	withCorner(button, 6)
	return button
end

local function newTextBox(placeholder: string, size: UDim2): TextBox
	local box = Instance.new("TextBox")
	box.Font = Enum.Font.Gotham
	box.TextSize = 14
	box.TextColor3 = TEXT_COLOR
	box.BackgroundColor3 = FIELD_COLOR
	box.ClearTextOnFocus = false
	box.Size = size
	box.PlaceholderText = placeholder
	box.Text = ""
	withCorner(box, 6)
	return box
end

--[[
	Everything below is built once, only for developers (see Start). Nothing
	here yields, so it's fine to run at the end of Start after the rank check
	already has.
]]
local function buildUI()
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "DevConsole"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1000
	gui.Enabled = false

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromOffset(460, 420)
	root.BackgroundColor3 = BACKGROUND_COLOR
	root.BorderSizePixel = 0
	root.Parent = gui
	withCorner(root, 8)

	-- Title row.
	local titleRow = Instance.new("Frame")
	titleRow.Name = "TitleRow"
	titleRow.BackgroundTransparency = 1
	titleRow.Position = UDim2.fromOffset(12, 10)
	titleRow.Size = UDim2.new(1, -24, 0, 28)
	titleRow.Parent = root

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -32, 1, 0)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 18
	title.TextColor3 = TEXT_COLOR
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Developer Console"
	title.Parent = titleRow

	local closeButton = newButton("X", UDim2.fromOffset(28, 28))
	closeButton.Name = "CloseButton"
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.fromScale(1, 0)
	closeButton.Parent = titleRow

	-- Target row.
	local targetRow = Instance.new("Frame")
	targetRow.Name = "TargetRow"
	targetRow.BackgroundTransparency = 1
	targetRow.Position = UDim2.fromOffset(12, 46)
	targetRow.Size = UDim2.new(1, -24, 0, 28)
	targetRow.Parent = root

	local targetBtn = newButton(`Target: {currentTargetName}`, UDim2.fromScale(1, 1))
	targetBtn.Name = "TargetButton"
	targetBtn.TextXAlignment = Enum.TextXAlignment.Left
	targetBtn.Parent = targetRow
	targetButton = targetBtn

	-- Target picker overlay -- hidden until the target row is clicked.
	local targetList = Instance.new("ScrollingFrame")
	targetList.Name = "TargetList"
	targetList.Position = UDim2.fromOffset(12, 76)
	targetList.Size = UDim2.new(1, -24, 0, 140)
	targetList.BackgroundColor3 = Color3.fromRGB(32, 32, 38)
	targetList.BorderSizePixel = 0
	targetList.ZIndex = 10
	targetList.Visible = false
	targetList.CanvasSize = UDim2.new()
	targetList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	targetList.ScrollBarThickness = 6
	targetList.Parent = root
	withCorner(targetList, 6)
	targetListFrame = targetList

	local targetListLayout = Instance.new("UIListLayout")
	targetListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	targetListLayout.Parent = targetList

	-- Body: one row per snapshot entry.
	local body = Instance.new("ScrollingFrame")
	body.Name = "Body"
	body.Position = UDim2.fromOffset(12, 82)
	body.Size = UDim2.new(1, -24, 1, -164)
	body.BackgroundColor3 = FIELD_COLOR
	body.BorderSizePixel = 0
	body.ScrollBarThickness = 6
	body.CanvasSize = UDim2.new()
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.Parent = root
	withCorner(body, 6)
	bodyScroll = body

	local bodyLayout = Instance.new("UIListLayout")
	bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bodyLayout.Padding = UDim.new(0, 2)
	bodyLayout.Parent = body

	-- New-key row.
	local newKeyRow = Instance.new("Frame")
	newKeyRow.Name = "NewKeyRow"
	newKeyRow.BackgroundTransparency = 1
	newKeyRow.Position = UDim2.new(0, 12, 1, -64)
	newKeyRow.Size = UDim2.new(1, -24, 0, 28)
	newKeyRow.Parent = root

	local pathBox = newTextBox("Inventory.Sword", UDim2.new(0.4, -4, 1, 0))
	pathBox.Name = "PathBox"
	pathBox.Parent = newKeyRow
	newKeyPathBox = pathBox

	local valueBox = newTextBox("1", UDim2.new(0.4, -4, 1, 0))
	valueBox.Name = "ValueBox"
	valueBox.Position = UDim2.new(0.4, 4, 0, 0)
	valueBox.Parent = newKeyRow
	newKeyValueBox = valueBox

	local setBtn = newButton("Set", UDim2.new(0.2, -8, 1, 0))
	setBtn.Name = "SetButton"
	setBtn.Position = UDim2.new(0.8, 8, 0, 0)
	setBtn.Parent = newKeyRow

	-- Status line.
	local status = Instance.new("TextLabel")
	status.Name = "StatusLabel"
	status.BackgroundTransparency = 1
	status.Position = UDim2.new(0, 12, 1, -28)
	status.Size = UDim2.new(1, -24, 0, 20)
	status.Font = Enum.Font.Gotham
	status.TextSize = 13
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.TextColor3 = MUTED_TEXT_COLOR
	status.Text = ""
	status.Parent = root
	statusLabel = status

	targetBtn.Activated:Connect(function()
		if targetListVisible then
			closeTargetList()
		else
			openTargetList()
		end
	end)

	setBtn.Activated:Connect(onCreateClicked)

	gui.Destroying:Connect(cleanup)

	gui.Parent = playerGui
	screenGui = gui

	local topbarIcon = Icon.new()
	topbarIcon:setLabel("Dev")
	topbarIcon:setCaption("Developer Console")
	topbarIcon:align("Right")
	topbarIcon:bindToggleKey(Enum.KeyCode.F4)
	topbarIcon:bindEvent("selected", open)
	topbarIcon:bindEvent("deselected", close)
	icon = topbarIcon

	closeButton.Activated:Connect(function()
		topbarIcon:deselect()
	end)
end

--[[
	The server told us whether we're a developer. We never work this out
	ourselves any more: the list lives in a ConfigService config, and
	ConfigService is server-only -- calling it from a client script errors.

	Idempotent on purpose. The server re-sends this to everyone on every config
	change, so the common case is being told the same answer we already have.
]]
local function setAccess(allowed: boolean)
	if allowed then
		if screenGui == nil then
			buildUI()
			log.info("ready")
		end
		return
	end

	--[[
		Revoked mid-session -- removed from the list, config republished. Tear the
		console down rather than leave a UI whose every command the server now
		rejects. Purely cosmetic, like the rest of this check: authority is the
		server's and DevService re-checks it per packet.
	]]
	local gui = screenGui
	if gui ~= nil then
		screenGui = nil
		gui:Destroy()
	end
	cleanup()
end

local DevConsoleController = {}

function DevConsoleController.Init()
	--[[
		Registered in Init, not Start. The server sends devAccess as soon as it
		sees us join, and a listener that does not exist yet misses it
		permanently and silently -- the same trap DataController.luau documents
		for Replica.OnNew, and the reason Init and Start are separate phases.
	]]
	Net.devAccess.listen(function(data)
		setAccess(data.allowed)
	end)

	Net.devResult.listen(function(data)
		applyResult(data)
		if data.ok then
			requestSnapshot()
		end
	end)

	Net.devSnapshot.listen(function(data)
		if data.targetUserId ~= currentTargetUserId then
			-- Late reply for a target we've since switched away from -- a
			-- repaint here would show the wrong player's data under the
			-- CURRENT target's label.
			return
		end
		latestEntries = data.entries
		rebuildRows()
	end)
end

--[[
	Ask the server whether we're a developer. The console is then built by
	setAccess() when devAccess comes back.

	Asking here rather than waiting to be told is deliberate. The server also
	pushes devAccess when it sees us join, but that push races us: a RemoteEvent
	fired at a client whose listener does not exist yet is dropped, not queued,
	so a fresh joiner could silently never get a console. By Start(), Init() has
	registered the listener, so the reply cannot be lost.
]]
function DevConsoleController.Start()
	Net.devRequestAccess.send()
end

return DevConsoleController
