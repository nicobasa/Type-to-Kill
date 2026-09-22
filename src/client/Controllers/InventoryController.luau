--!strict
--[[
	The Inventory: two tabs, CASES and COSMETICS, each a grid of square cards,
	and the reveal when a case is opened.

	Studio owns the screen (Screens.Inventory); this finds it and drives it. It
	creates clones of the authored CaseCardTemplate, TitleCardTemplate and
	ReelRowTemplate, and nothing else.

	EVERYTHING HERE IS DRAWN FROM THE PROFILE. Owned cases (Inventory), owned
	cosmetics and the equipped ones are observed from the private profile
	replica, so opening, buying and equipping all redraw the same way: the
	server writes, the replica arrives, the tab repaints. Nothing is drawn
	optimistically from a click. Only what the player owns is shown; what a
	case can hold is the Shop's preview.

	THE COSMETICS TAB IS FOR EVERY KIND OF COSMETIC, not only titles. Titles
	are the only kind today, so paintCosmetics draws Titles; a new kind adds
	its own cards to the same grid (and its own op in the admin panel).

	OPENING A CASE is a request (Net.openCase). The server takes the case,
	rolls, writes the title and sends Net.caseOpened as a receipt. The reveal
	here is only the show, in two acts:

	  1. The reel: a vertical strip of titles falls through a window, slows
	     down, and stops with the rolled title on the centre line. It only
	     starts moving once the receipt is in, so where it stops is known from
	     the start, like a real roulette; the rows either side are filler,
	     rolled here with the same weights the server uses.
	  2. The result: the reel fades away and the item is shown large in the
	     middle, with EQUIP, OK, and OPEN ANOTHER while the player has more of
	     that case.

	It never decides anything -- if the receipt never arrives, the reveal gives
	up and says so, and whatever the server did is already in the profile.

	Nothing flashes: the rows slide and the result grows in once; brightness
	never pulses (GAMEPLAY.md, the photosensitivity rule).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Cosmetics = require(ReplicatedStorage.Shared.Cosmetics)
local DataController = require(script.Parent.DataController)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local PanelOverlay = require(script.Parent.Parent.UI.PanelOverlay)
local TitleStyle = require(script.Parent.Parent.UI.TitleStyle)
local UIController = require(script.Parent.UIController)

local log = Log.new("InventoryController")

local player = Players.LocalPlayer

local SCREEN_NAME = "Inventory"
local SCREEN_TIMEOUT = 10

type Tab = "Cases" | "Cosmetics"

--[[
	The reel. ROW_COUNT rows are stacked bottom (1) to top (ROW_COUNT) in a
	strip taller than the window; VISIBLE rows fit in the window at once. The
	strip starts with row START centred and moves DOWN until row WINNER is
	centred, so the titles fall.
]]
local REEL_VISIBLE = 5
local REEL_ROW_COUNT = 40
local REEL_START = 3
local REEL_WINNER = 36
local REEL_SPIN_TIME = 5
-- The spin stops a little off the line, by up to this much of a row, then
-- settles onto it: a reel that lands dead centre every time looks scripted.
local REEL_OVERSHOOT = 0.35
local REEL_SETTLE_TIME = 0.35
-- How long the landed row is held before the reel gives way to the result.
local REEL_HOLD = 0.7
local REEL_FADE_TIME = 0.3
-- If the receipt has not come by then, stop and say so.
local REEL_TIMEOUT = 6
local REEL_POLL = 0.05

-- The result grows from this scale to 1 as it appears.
local RESULT_START_SCALE = 0.6
local RESULT_GROW_TIME = 0.45

local TAB_ACTIVE_COLOR = Color3.fromRGB(0, 200, 255)
local TAB_IDLE_COLOR = Color3.fromRGB(44, 50, 66)
local EQUIPPED_COLOR = Color3.fromRGB(0, 200, 255)
local MUTED_COLOR = Color3.fromRGB(140, 150, 168)
local NEW_COLOR = Color3.fromRGB(120, 230, 150)

type Elements = {
	casesTab: GuiButton,
	cosmeticsTab: GuiButton,
	casesPage: GuiObject,
	cosmeticsPage: GuiObject,
	caseCardTemplate: GuiObject,
	titleCardTemplate: GuiButton,
	emptyLabel: TextLabel,
	reveal: GuiObject,
	revealHeader: TextLabel,
	reel: CanvasGroup,
	reelStrip: GuiObject,
	reelHighlight: GuiObject,
	reelRowTemplate: GuiObject,
	result: GuiObject,
	resultScale: UIScale,
	resultTitle: TextLabel,
	resultRarity: TextLabel,
	resultNote: TextLabel,
	revealEquip: GuiButton,
	revealClose: GuiButton,
	openAnother: GuiButton,
	openAnotherLabel: TextLabel,
}

type Reel = {
	-- The receipt, once it has arrived.
	result: { titleId: string, duplicate: boolean, refund: number }?,
	-- Bumped per open, so a stale reveal thread stops itself.
	token: number,
}

local InventoryController = {}

local screen: Elements? = nil
local tab: Tab = "Cases"
local reel: Reel = { result = nil, token = 0 }
-- The title the reveal landed on, for its EQUIP button.
local revealedTitleId: string? = nil
-- The case being opened, for OPEN ANOTHER.
local revealCaseId: string? = nil
-- True once the result is showing, so OPEN ANOTHER tracks the case count.
local resultShowing = false
-- Puts the Inventory's own content back when the reveal closes; nil while
-- the reveal is not showing.
local restoreReveal: PanelOverlay.Restore? = nil

local function data(): any
	return DataController.getData()
end

local function ownsTitle(titleId: string): boolean
	local current = data()
	local titles = if current ~= nil then current.Titles else nil
	return type(titles) == "table" and titles[titleId] == true
end

local function equippedTitle(): string
	local current = data()
	local equipped = if current ~= nil then current.EquippedTitle else nil
	return if type(equipped) == "string" then equipped else ""
end

local function caseCount(caseId: string): number
	local current = data()
	local inventory = if current ~= nil then current.Inventory else nil
	local value = if type(inventory) == "table" then inventory[caseId] else nil
	return if type(value) == "number" and value == value then value else 0
end

local function clearClones(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

-- Finds a descendant by a dotted path under `root`, of the given class.
local function find(root: Instance, path: string, className: string): Instance?
	local current: Instance? = root
	for segment in string.gmatch(path, "[^%.]+") do
		if current == nil then
			return nil
		end
		current = current:FindFirstChild(segment)
	end
	if current == nil or not current:IsA(className) then
		return nil
	end
	return current
end

local function showEmpty(ui: Elements, text: string?)
	ui.emptyLabel.Text = text or ""
	-- Never over the reveal: opening the last case empties the tab mid-reveal.
	ui.emptyLabel.Visible = text ~= nil and not ui.reveal.Visible
end

--========================================================================
-- THE REVEAL
--========================================================================

-- The strip's Y (window heights) that puts row `index` on the centre line,
-- `offset` rows past it.
local function stripY(index: number, offset: number): number
	return 0.5 - (REEL_ROW_COUNT - index + 0.5 + offset) / REEL_VISIBLE
end

local function paintReelRow(row: GuiObject, titleId: string)
	local titleLabel = find(row, "TitleLabel", "TextLabel") :: TextLabel?
	local rarityLabel = find(row, "RarityLabel", "TextLabel") :: TextLabel?
	local bar = find(row, "RarityBar", "GuiObject") :: GuiObject?
	if titleLabel ~= nil then
		TitleStyle.apply(titleLabel, titleId)
	end
	if rarityLabel ~= nil then
		TitleStyle.applyRarity(rarityLabel, titleId)
	end
	local title = Cosmetics.title(titleId)
	local rarity = if title ~= nil then Cosmetics.rarity(title.Rarity) else nil
	if bar ~= nil and rarity ~= nil then
		bar.BackgroundColor3 = rarity.Color
	end
end

local function setHighlightColor(ui: Elements, color: Color3)
	local edge = ui.reelHighlight:FindFirstChildOfClass("UIStroke")
	if edge ~= nil then
		edge.Color = color
	end
	ui.reelHighlight.BackgroundColor3 = color
end

-- Fills the strip with filler rolled at the real odds; returns row WINNER.
local function buildReel(ui: Elements): GuiObject?
	clearClones(ui.reelStrip)
	ui.reelStrip.Size = UDim2.fromScale(1, REEL_ROW_COUNT / REEL_VISIBLE)
	ui.reelStrip.Position = UDim2.fromScale(0, stripY(REEL_START, 0))

	local random = Random.new()
	local winner: GuiObject? = nil
	for index = 1, REEL_ROW_COUNT do
		local row = ui.reelRowTemplate:Clone() :: GuiObject
		row.Name = `Row{index}`
		row.Size = UDim2.fromScale(1, 1 / REEL_ROW_COUNT)
		row.Position = UDim2.fromScale(0, (REEL_ROW_COUNT - index) / REEL_ROW_COUNT)
		row.Visible = true
		paintReelRow(row, Cosmetics.roll(random).Id)
		row.Parent = ui.reelStrip
		if index == REEL_WINNER then
			winner = row
		end
	end
	return winner
end

-- OPEN ANOTHER shows only while the player still has one of this case.
local function paintOpenAnother()
	local ui = screen
	local caseId = revealCaseId
	if ui == nil then
		return
	end
	local left = if caseId ~= nil then caseCount(caseId) else 0
	ui.openAnother.Visible = resultShowing and left > 0
	ui.openAnotherLabel.Text = `OPEN ANOTHER ({left} LEFT)`
end

-- Plays one tween to the end; false if a newer reveal took over meanwhile.
local function play(tween: Tween, token: number): boolean
	tween:Play()
	tween.Completed:Wait()
	return reel.token == token
end

local function showResult(ui: Elements, result: { titleId: string, duplicate: boolean, refund: number }, token: number)
	-- The reel steps aside...
	if not play(TweenService:Create(ui.reel, TweenInfo.new(REEL_FADE_TIME), { GroupTransparency = 1 }), token) then
		return
	end
	ui.reel.Visible = false
	clearClones(ui.reelStrip)

	-- ...and the item takes the middle.
	TitleStyle.apply(ui.resultTitle, result.titleId)
	TitleStyle.applyRarity(ui.resultRarity, result.titleId)
	-- A duplicate is still a title the player owns, so it can be equipped too.
	revealedTitleId = result.titleId
	if result.duplicate then
		ui.resultNote.Text = if result.refund > 0 then "DUPLICATE -- +$" .. result.refund .. " CASH" else "DUPLICATE"
		ui.resultNote.TextColor3 = MUTED_COLOR
	else
		ui.resultNote.Text = "NEW TITLE!"
		ui.resultNote.TextColor3 = NEW_COLOR
	end
	ui.revealHeader.Text = "YOU GOT"
	ui.resultScale.Scale = RESULT_START_SCALE
	ui.result.Visible = true
	resultShowing = true
	ui.revealEquip.Visible = true
	ui.revealClose.Visible = true
	paintOpenAnother()
	TweenService:Create(
		ui.resultScale,
		TweenInfo.new(RESULT_GROW_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	):Play()
end

local function openCase(caseId: string)
	local ui = screen
	if ui == nil or caseCount(caseId) <= 0 then
		return
	end

	reel.token += 1
	reel.result = nil
	revealedTitleId = nil
	revealCaseId = caseId
	resultShowing = false
	local token = reel.token

	local case = Cosmetics.case(caseId)
	ui.revealHeader.Text = `OPENING {if case ~= nil then string.upper(case.DisplayName) else "CASE"}`
	ui.result.Visible = false
	ui.revealEquip.Visible = false
	ui.revealClose.Visible = false
	ui.openAnother.Visible = false
	ui.reelHighlight.BackgroundTransparency = 1
	setHighlightColor(ui, EQUIPPED_COLOR)
	ui.reel.GroupTransparency = 0
	ui.reel.Visible = true
	local winnerRow = buildReel(ui)
	-- The reveal replaces the Inventory's content rather than sitting on top
	-- of it. OPEN ANOTHER reopens inside a reveal that is already showing.
	if restoreReveal == nil then
		restoreReveal = PanelOverlay.show(ui.reveal)
	end

	Net.openCase.send({ caseId = caseId })

	task.spawn(function()
		-- Wait for the receipt: the reel only moves once it knows where to stop.
		local waited = 0
		while reel.token == token and reel.result == nil and waited < REEL_TIMEOUT do
			task.wait(REEL_POLL)
			waited += REEL_POLL
		end
		local current = screen
		local result = reel.result
		if reel.token ~= token or current == nil then
			return
		end
		if result == nil or winnerRow == nil then
			current.reel.Visible = false
			TitleStyle.apply(current.resultTitle, nil)
			current.resultScale.Scale = 1
			current.resultTitle.Text = "COULDN'T OPEN"
			current.resultTitle.TextColor3 = MUTED_COLOR
			current.resultRarity.Text = ""
			current.resultNote.Text = "Check your inventory in a moment."
			current.resultNote.TextColor3 = MUTED_COLOR
			current.result.Visible = true
			current.revealClose.Visible = true
			return
		end

		paintReelRow(winnerRow, result.titleId)

		local overshoot = (Random.new():NextNumber() * 2 - 1) * REEL_OVERSHOOT
		local spin = TweenService:Create(
			current.reelStrip,
			TweenInfo.new(REEL_SPIN_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{ Position = UDim2.fromScale(0, stripY(REEL_WINNER, overshoot)) }
		)
		if not play(spin, token) then
			return
		end
		local settle = TweenService:Create(
			current.reelStrip,
			TweenInfo.new(REEL_SETTLE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
			{ Position = UDim2.fromScale(0, stripY(REEL_WINNER, 0)) }
		)
		if not play(settle, token) then
			return
		end

		-- Land: the centre band takes the rarity's colour, softly, and holds.
		local title = Cosmetics.title(result.titleId)
		local rarity = if title ~= nil then Cosmetics.rarity(title.Rarity) else nil
		if rarity ~= nil then
			setHighlightColor(current, rarity.Color)
			TweenService:Create(current.reelHighlight, TweenInfo.new(0.4), { BackgroundTransparency = 0.82 }):Play()
		end
		task.wait(REEL_HOLD)
		if reel.token ~= token then
			return
		end

		showResult(current, result, token)
	end)
end

--========================================================================
-- CASES TAB
--========================================================================

local function paintCases(ui: Elements)
	clearClones(ui.casesPage)
	local any = false
	for index, case in Cosmetics.CASES do
		local count = caseCount(case.Id)
		if count <= 0 then
			continue
		end

		local card = ui.caseCardTemplate:Clone() :: GuiObject
		local nameLabel = find(card, "NameLabel", "TextLabel") :: TextLabel?
		local countLabel = find(card, "CountLabel", "TextLabel") :: TextLabel?
		local image = find(card, "Art.Image", "ImageLabel") :: ImageLabel?
		local placeholder = find(card, "Art.Placeholder", "GuiObject") :: GuiObject?
		local openButton = find(card, "OpenButton", "GuiButton") :: GuiButton?
		if nameLabel == nil or countLabel == nil or image == nil or placeholder == nil or openButton == nil then
			card:Destroy()
			log.warn("CaseCardTemplate needs NameLabel, CountLabel, Art.Image, Art.Placeholder and OpenButton")
			return
		end
		any = true

		nameLabel.Text = case.DisplayName
		countLabel.Text = `x{count}`
		image.Image = case.Image
		image.Visible = case.Image ~= ""
		placeholder.Visible = case.Image == ""
		local caseId = case.Id
		openButton.Activated:Connect(function()
			openCase(caseId)
		end)

		card.Name = caseId
		card.LayoutOrder = index
		card.Visible = true
		card.Parent = ui.casesPage
	end

	if tab == "Cases" then
		showEmpty(ui, if any then nil else "No cases yet. Buy one in the Shop.")
	end
end

--========================================================================
-- COSMETICS TAB
--========================================================================

-- Every cosmetic the player owns. Titles are the only kind today, drawn in
-- catalog order (rarest last).
local function paintCosmetics(ui: Elements)
	clearClones(ui.cosmeticsPage)
	local equipped = equippedTitle()
	local any = false
	for index, title in Cosmetics.TITLES do
		if not ownsTitle(title.Id) then
			continue
		end

		local card = ui.titleCardTemplate:Clone() :: GuiButton
		local titleLabel = find(card, "TitleLabel", "TextLabel") :: TextLabel?
		local rarityLabel = find(card, "RarityLabel", "TextLabel") :: TextLabel?
		local statusLabel = find(card, "StatusLabel", "TextLabel") :: TextLabel?
		if titleLabel == nil or rarityLabel == nil or statusLabel == nil then
			card:Destroy()
			log.warn("TitleCardTemplate needs TitleLabel, RarityLabel and StatusLabel")
			return
		end
		any = true

		TitleStyle.apply(titleLabel, title.Id)
		TitleStyle.applyRarity(rarityLabel, title.Id)
		local isEquipped = equipped == title.Id
		statusLabel.Text = if isEquipped then "EQUIPPED" else "EQUIP"
		statusLabel.TextColor3 = if isEquipped then EQUIPPED_COLOR else MUTED_COLOR
		local stroke = card:FindFirstChildOfClass("UIStroke")
		local rarity = Cosmetics.rarity(title.Rarity)
		if stroke ~= nil then
			stroke.Color = if isEquipped then EQUIPPED_COLOR elseif rarity ~= nil then rarity.Color else stroke.Color
			stroke.Thickness = if isEquipped then 3 else 1.5
		end

		local titleId = title.Id
		card.Activated:Connect(function()
			-- Pressing the equipped one takes it off.
			Net.equipTitle.send({ titleId = if equippedTitle() == titleId then "" else titleId })
		end)

		card.Name = titleId
		card.LayoutOrder = index
		card.Visible = true
		card.Parent = ui.cosmeticsPage
	end

	if tab == "Cosmetics" then
		showEmpty(ui, if any then nil else "No cosmetics yet. Open a case to get some.")
	end
end

--========================================================================
-- TABS
--========================================================================

local function setTabLook(button: GuiButton, active: boolean)
	local bar = button:FindFirstChild("SelectedBar")
	if bar ~= nil and bar:IsA("GuiObject") then
		bar.BackgroundColor3 = if active then TAB_ACTIVE_COLOR else TAB_IDLE_COLOR
	end
end

local function showTab(which: Tab)
	tab = which
	local ui = screen
	if ui == nil then
		return
	end
	ui.casesPage.Visible = which == "Cases"
	ui.cosmeticsPage.Visible = which == "Cosmetics"
	setTabLook(ui.casesTab, which == "Cases")
	setTabLook(ui.cosmeticsTab, which == "Cosmetics")
	-- Each paint sets the empty message for its own tab only.
	paintCases(ui)
	paintCosmetics(ui)
end

--========================================================================
-- BINDING
--========================================================================

local function resolve(gui: Instance): Elements?
	local root = gui:FindFirstChild("Root")
	if root == nil then
		log.warn(`{SCREEN_NAME} has no Root -- the inventory will not be drawn`)
		return nil
	end

	local missing: { string } = {}
	local function grab(path: string, className: string): Instance?
		local found = find(root, path, className)
		if found == nil then
			table.insert(missing, path)
		end
		return found
	end

	local casesTab = grab("Panel.Tabs.CasesTab", "GuiButton") :: GuiButton?
	local cosmeticsTab = grab("Panel.Tabs.CosmeticsTab", "GuiButton") :: GuiButton?
	local casesPage = grab("Panel.CasesPage", "GuiObject") :: GuiObject?
	local cosmeticsPage = grab("Panel.CosmeticsPage", "GuiObject") :: GuiObject?
	local caseCardTemplate = grab("Panel.CaseCardTemplate", "GuiObject") :: GuiObject?
	local titleCardTemplate = grab("Panel.TitleCardTemplate", "GuiButton") :: GuiButton?
	local emptyLabel = grab("Panel.EmptyLabel", "TextLabel") :: TextLabel?
	local reveal = grab("Panel.Reveal", "GuiObject") :: GuiObject?
	local revealHeader = grab("Panel.Reveal.HeaderLabel", "TextLabel") :: TextLabel?
	local reelGroup = grab("Panel.Reveal.Reel", "CanvasGroup") :: CanvasGroup?
	local reelStrip = grab("Panel.Reveal.Reel.Window.Strip", "GuiObject") :: GuiObject?
	local reelHighlight = grab("Panel.Reveal.Reel.Window.Highlight", "GuiObject") :: GuiObject?
	local reelRowTemplate = grab("Panel.Reveal.ReelRowTemplate", "GuiObject") :: GuiObject?
	local result = grab("Panel.Reveal.Result", "GuiObject") :: GuiObject?
	local resultScale = grab("Panel.Reveal.Result.UIScale", "UIScale") :: UIScale?
	local resultTitle = grab("Panel.Reveal.Result.TitleLabel", "TextLabel") :: TextLabel?
	local resultRarity = grab("Panel.Reveal.Result.RarityLabel", "TextLabel") :: TextLabel?
	local resultNote = grab("Panel.Reveal.Result.NoteLabel", "TextLabel") :: TextLabel?
	local revealEquip = grab("Panel.Reveal.Buttons.EquipButton", "GuiButton") :: GuiButton?
	local revealClose = grab("Panel.Reveal.Buttons.CloseButton", "GuiButton") :: GuiButton?
	local openAnother = grab("Panel.Reveal.Buttons.OpenAnotherButton", "GuiButton") :: GuiButton?
	local openAnotherLabel = grab("Panel.Reveal.Buttons.OpenAnotherButton.Label", "TextLabel") :: TextLabel?

	if
		casesTab == nil
		or cosmeticsTab == nil
		or casesPage == nil
		or cosmeticsPage == nil
		or caseCardTemplate == nil
		or titleCardTemplate == nil
		or emptyLabel == nil
		or reveal == nil
		or revealHeader == nil
		or reelGroup == nil
		or reelStrip == nil
		or reelHighlight == nil
		or reelRowTemplate == nil
		or result == nil
		or resultScale == nil
		or resultTitle == nil
		or resultRarity == nil
		or resultNote == nil
		or revealEquip == nil
		or revealClose == nil
		or openAnother == nil
		or openAnotherLabel == nil
	then
		log.warn(`{SCREEN_NAME} is missing {table.concat(missing, ", ")} -- the inventory will not be drawn`)
		return nil
	end

	caseCardTemplate.Visible = false
	titleCardTemplate.Visible = false
	reelRowTemplate.Visible = false
	reveal.Visible = false

	return {
		casesTab = casesTab,
		cosmeticsTab = cosmeticsTab,
		casesPage = casesPage,
		cosmeticsPage = cosmeticsPage,
		caseCardTemplate = caseCardTemplate,
		titleCardTemplate = titleCardTemplate,
		emptyLabel = emptyLabel,
		reveal = reveal,
		revealHeader = revealHeader,
		reel = reelGroup,
		reelStrip = reelStrip,
		reelHighlight = reelHighlight,
		reelRowTemplate = reelRowTemplate,
		result = result,
		resultScale = resultScale,
		resultTitle = resultTitle,
		resultRarity = resultRarity,
		resultNote = resultNote,
		revealEquip = revealEquip,
		revealClose = revealClose,
		openAnother = openAnother,
		openAnotherLabel = openAnotherLabel,
	}
end

local function closeReveal(ui: Elements)
	reel.token += 1
	resultShowing = false
	local restore = restoreReveal
	restoreReveal = nil
	if restore ~= nil then
		restore()
	end
	ui.reveal.Visible = false
	clearClones(ui.reelStrip)
	TitleStyle.apply(ui.resultTitle, nil)
	-- The pages and the empty message were hidden under the reveal; draw them
	-- for whatever changed meanwhile (a case opened is a case gone).
	showTab(tab)
end

local function bind(ui: Elements)
	ui.casesTab.Activated:Connect(function()
		showTab("Cases")
	end)
	ui.cosmeticsTab.Activated:Connect(function()
		showTab("Cosmetics")
	end)
	ui.revealClose.Activated:Connect(function()
		closeReveal(ui)
	end)
	ui.revealEquip.Activated:Connect(function()
		local titleId = revealedTitleId
		if titleId ~= nil then
			Net.equipTitle.send({ titleId = titleId })
		end
		closeReveal(ui)
	end)
	ui.openAnother.Activated:Connect(function()
		local caseId = revealCaseId
		if caseId ~= nil and resultShowing then
			openCase(caseId)
		end
	end)

	showTab(tab)
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

		screensFolder.Destroying:Wait()
		screen = nil
		reel.token += 1
		resultShowing = false
		restoreReveal = nil
		while playerGui:FindFirstChild("Screens") == screensFolder do
			playerGui.ChildRemoved:Wait()
		end
	end
end

function InventoryController.Init()
	-- In Init so a receipt that lands before Start is not dropped (a packet
	-- with no listener yet is not queued).
	Net.caseOpened.listen(function(receipt)
		reel.result = { titleId = receipt.titleId, duplicate = receipt.duplicate, refund = receipt.refund }
	end)
end

function InventoryController.Start()
	DataController.observe({ "Inventory" }, function()
		local ui = screen
		if ui ~= nil then
			paintCases(ui)
		end
		paintOpenAnother()
	end)
	local function repaintCosmetics()
		local ui = screen
		if ui ~= nil then
			paintCosmetics(ui)
		end
	end
	DataController.observe({ "Titles" }, repaintCosmetics)
	DataController.observe({ "EquippedTitle" }, repaintCosmetics)

	-- Every open starts on the last tab used, with no leftover reveal.
	UIController.onOpen(SCREEN_NAME, function()
		local ui = screen
		if ui ~= nil then
			closeReveal(ui)
			showTab(tab)
		end
	end)

	attachLoop()
end

return InventoryController
