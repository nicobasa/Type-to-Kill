--!strict
--[[
	The Shop: a catalog grid of things to buy, the drop odds behind a "?" in
	the corner, and a preview of what each case holds.

	Studio owns the screen (Screens.Shop); this finds it and drives it. It
	creates clones of the authored ItemCardTemplate (one per case in
	Cosmetics.CASES), OddsTemplate (one per rarity) and PreviewItemTemplate
	(one per title in the previewed case), and nothing else.

	BUYING IS A REQUEST. A card's Cash button sends Net.buyCase and nothing
	else: the server takes the price from the catalog and the Cash from the
	profile (CosmeticsService). The "not enough Cash" message is shown from the
	client's own copy of the balance so it is instant, but it is a courtesy --
	the server refuses a short balance whatever this screen says. A purchase
	that worked shows up as an owned count going up, observed from the profile,
	never as an answer from the server.

	THE ROBUX BUTTONS ARE NOT WIRED. They are built and show the price with the
	Robux icon, but there is no developer product yet, so pressing one says so.
	Wiring it is MarketplaceService:PromptProductPurchase here and a
	ProcessReceipt on the server that calls InventoryService.add -- see
	CosmeticsService's header.

	THE ODDS ARE ONE TABLE FOR EVERY CASE. They come from
	Cosmetics.rarityChance, the same weights the server rolls with, so they
	are shown once, behind the "?" (on hover, or a tap on touch), not per card.
	Roblox requires the odds of a paid random item to be available before
	purchase; the "?" and the preview are both on the screen that sells it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Cosmetics = require(ReplicatedStorage.Shared.Cosmetics)
local DataController = require(script.Parent.DataController)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local PanelOverlay = require(script.Parent.Parent.UI.PanelOverlay)
local TitleStyle = require(script.Parent.Parent.UI.TitleStyle)
local UIController = require(script.Parent.UIController)

local log = Log.new("ShopController")

local player = Players.LocalPlayer

local SCREEN_NAME = "Shop"
local SCREEN_TIMEOUT = 10

local STATUS_OK_COLOR = Color3.fromRGB(120, 230, 150)
local STATUS_WARN_COLOR = Color3.fromRGB(255, 120, 120)
local STATUS_INFO_COLOR = Color3.fromRGB(140, 150, 168)
local OWNED_COLOR = Color3.fromRGB(0, 200, 255)

type Elements = {
	balance: TextLabel,
	catalog: GuiObject,
	itemCardTemplate: GuiObject,
	oddsButton: GuiButton,
	oddsPopup: GuiObject,
	oddsList: GuiObject,
	oddsTemplate: GuiObject,
	preview: GuiObject,
	previewHeader: TextLabel,
	previewSubtitle: TextLabel,
	previewGrid: GuiObject,
	previewItemTemplate: GuiObject,
	previewClose: GuiButton,
	status: TextLabel,
}

-- The parts of one catalog card that change after it is built.
type Card = {
	owned: TextLabel,
}

local ShopController = {}

local screen: Elements? = nil
local cards: { [string]: Card } = {}
-- The case whose contents the preview shows, so an owned-title change can
-- redraw it; nil while the preview is closed.
local previewing: string? = nil
-- Puts the catalog back when the preview closes; nil while it is closed.
local restorePreview: PanelOverlay.Restore? = nil

local function groupThousands(value: number): string
	local text = tostring(math.floor(value))
	local grouped = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (grouped:gsub("^,", ""))
end

local function cash(): number
	local data = DataController.getData()
	local value = if data ~= nil then data.Cash else nil
	return if type(value) == "number" and value == value then value else 0
end

local function ownedCount(caseId: string): number
	local data = DataController.getData()
	local inventory = if data ~= nil then data.Inventory else nil
	local value = if type(inventory) == "table" then inventory[caseId] else nil
	return if type(value) == "number" and value == value then value else 0
end

local function ownsTitle(titleId: string): boolean
	local data = DataController.getData()
	local titles = if data ~= nil then data.Titles else nil
	return type(titles) == "table" and titles[titleId] == true
end

local function setStatus(text: string, color: Color3)
	local ui = screen
	if ui == nil then
		return
	end
	ui.status.Text = text
	ui.status.TextColor3 = color
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

local function paint()
	local ui = screen
	if ui == nil then
		return
	end
	ui.balance.Text = "$" .. groupThousands(cash())
	for caseId, card in cards do
		local count = ownedCount(caseId)
		card.owned.Text = if count == 0 then "" else `OWNED x{count}`
		card.owned.TextColor3 = OWNED_COLOR
	end
end

local function buyWithCash(case: Cosmetics.Case)
	if cash() < case.CashPrice then
		setStatus(
			`NOT ENOUGH CASH -- YOU NEED {"$" .. groupThousands(case.CashPrice - cash())} MORE`,
			STATUS_WARN_COLOR
		)
		return
	end
	Net.buyCase.send({ caseId = case.Id })
	setStatus("BUYING...", STATUS_INFO_COLOR)
end

local function buyWithRobux()
	setStatus("ROBUX PURCHASES ARE COMING SOON", STATUS_INFO_COLOR)
end

--========================================================================
-- ODDS
--========================================================================

-- One row per rarity that can drop, rarest last, from the authored template.
local function buildOdds(ui: Elements)
	clearClones(ui.oddsList)
	for index, rarity in Cosmetics.RARITIES do
		local chance = Cosmetics.rarityChance(rarity.Id)
		if chance <= 0 then
			continue
		end
		local row = ui.oddsTemplate:Clone() :: GuiObject
		local rarityLabel = find(row, "RarityLabel", "TextLabel") :: TextLabel?
		local chanceLabel = find(row, "ChanceLabel", "TextLabel") :: TextLabel?
		if rarityLabel == nil or chanceLabel == nil then
			row:Destroy()
			log.warn("OddsTemplate needs RarityLabel and ChanceLabel -- the odds cannot be drawn")
			return
		end
		rarityLabel.Text = rarity.DisplayName
		rarityLabel.TextColor3 = rarity.Color
		-- One decimal, so a 1% rarity does not round away to "0%".
		chanceLabel.Text = string.format("%.1f%%", chance * 100)
		row.Name = `{rarity.Id}Odds`
		row.LayoutOrder = index
		row.Visible = true
		row.Parent = ui.oddsList
	end
end

--========================================================================
-- PREVIEW
--========================================================================

local function paintPreview()
	local ui = screen
	local caseId = previewing
	if ui == nil or caseId == nil then
		return
	end
	local case = Cosmetics.case(caseId)
	if case == nil then
		return
	end

	clearClones(ui.previewGrid)
	local contents = Cosmetics.contents(caseId)
	local ownedTotal = 0
	for index, title in contents do
		local item = ui.previewItemTemplate:Clone() :: GuiObject
		local titleLabel = find(item, "TitleLabel", "TextLabel") :: TextLabel?
		local rarityLabel = find(item, "RarityLabel", "TextLabel") :: TextLabel?
		local ownedLabel = find(item, "OwnedLabel", "TextLabel") :: TextLabel?
		if titleLabel == nil or rarityLabel == nil or ownedLabel == nil then
			item:Destroy()
			log.warn("PreviewItemTemplate needs TitleLabel, RarityLabel and OwnedLabel")
			return
		end

		TitleStyle.apply(titleLabel, title.Id)
		TitleStyle.applyRarity(rarityLabel, title.Id)
		local owned = ownsTitle(title.Id)
		ownedLabel.Visible = owned
		if owned then
			ownedTotal += 1
		end
		-- The card's edge in the rarity's colour, so the grid reads by rarity
		-- at a glance (the rarity is also spelled out on the card).
		local rarity = Cosmetics.rarity(title.Rarity)
		local stroke = item:FindFirstChildOfClass("UIStroke")
		if stroke ~= nil and rarity ~= nil then
			stroke.Color = rarity.Color
		end

		item.Name = title.Id
		item.LayoutOrder = index
		item.Visible = true
		item.Parent = ui.previewGrid
	end

	ui.previewHeader.Text = `{string.upper(case.DisplayName)} -- CONTENTS`
	ui.previewSubtitle.Text = `{#contents} items -- you own {ownedTotal}`
end

local function openPreview(caseId: string)
	local ui = screen
	if ui == nil then
		return
	end
	previewing = caseId
	ui.oddsPopup.Visible = false
	-- The preview replaces the catalog rather than sitting on top of it, so
	-- nothing behind it shows through or takes a click.
	if restorePreview == nil then
		restorePreview = PanelOverlay.show(ui.preview)
	end
	paintPreview()
end

local function closePreview()
	previewing = nil
	local restore = restorePreview
	restorePreview = nil
	if restore ~= nil then
		restore()
	end
	local ui = screen
	if ui ~= nil then
		ui.preview.Visible = false
		clearClones(ui.previewGrid)
	end
end

--========================================================================
-- CATALOG
--========================================================================

local function buildCatalog(ui: Elements)
	clearClones(ui.catalog)
	table.clear(cards)

	for index, case in Cosmetics.CASES do
		local root = ui.itemCardTemplate:Clone() :: GuiObject
		local nameLabel = find(root, "NameLabel", "TextLabel") :: TextLabel?
		local descriptionLabel = find(root, "DescriptionLabel", "TextLabel") :: TextLabel?
		local ownedLabel = find(root, "OwnedLabel", "TextLabel") :: TextLabel?
		local image = find(root, "Art.Image", "ImageLabel") :: ImageLabel?
		local placeholder = find(root, "Art.Placeholder", "GuiObject") :: GuiObject?
		local previewButton = find(root, "Art.PreviewButton", "GuiButton") :: GuiButton?
		local buyCash = find(root, "BuyCashButton", "GuiButton") :: GuiButton?
		local buyCashLabel = find(root, "BuyCashButton.PriceLabel", "TextLabel") :: TextLabel?
		local buyRobux = find(root, "BuyRobuxButton", "GuiButton") :: GuiButton?
		local buyRobuxLabel = find(root, "BuyRobuxButton.PriceLabel", "TextLabel") :: TextLabel?
		if
			nameLabel == nil
			or descriptionLabel == nil
			or ownedLabel == nil
			or image == nil
			or placeholder == nil
			or previewButton == nil
			or buyCash == nil
			or buyCashLabel == nil
			or buyRobux == nil
			or buyRobuxLabel == nil
		then
			root:Destroy()
			log.warn(
				"ItemCardTemplate needs NameLabel, DescriptionLabel, OwnedLabel, Art.Image, Art.Placeholder, "
					.. "Art.PreviewButton and BuyCashButton/BuyRobuxButton with a PriceLabel each"
			)
			return
		end

		nameLabel.Text = case.DisplayName
		descriptionLabel.Text = case.Description
		image.Image = case.Image
		image.Visible = case.Image ~= ""
		placeholder.Visible = case.Image == ""
		buyCashLabel.Text = "$" .. groupThousands(case.CashPrice)
		buyRobuxLabel.Text = `{case.RobuxPrice}`

		local caseId = case.Id
		-- Connections die with the card, which dies with the screen.
		buyCash.Activated:Connect(function()
			buyWithCash(case)
		end)
		buyRobux.Activated:Connect(buyWithRobux)
		previewButton.Activated:Connect(function()
			openPreview(caseId)
		end)

		root.Name = caseId
		root.LayoutOrder = index
		root.Visible = true
		root.Parent = ui.catalog
		cards[caseId] = { owned = ownedLabel }
	end
end

--========================================================================
-- BINDING
--========================================================================

local function resolve(gui: Instance): Elements?
	local root = gui:FindFirstChild("Root")
	if root == nil then
		log.warn(`{SCREEN_NAME} has no Root -- the shop will not be drawn`)
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

	local balance = grab("Panel.Header.BalanceLabel", "TextLabel") :: TextLabel?
	local catalog = grab("Panel.Catalog", "GuiObject") :: GuiObject?
	local itemCardTemplate = grab("Panel.ItemCardTemplate", "GuiObject") :: GuiObject?
	local oddsButton = grab("Panel.Header.OddsButton", "GuiButton") :: GuiButton?
	local oddsPopup = grab("Panel.OddsPopup", "GuiObject") :: GuiObject?
	local oddsList = grab("Panel.OddsPopup.List", "GuiObject") :: GuiObject?
	local oddsTemplate = grab("Panel.OddsPopup.OddsTemplate", "GuiObject") :: GuiObject?
	local preview = grab("Panel.Preview", "GuiObject") :: GuiObject?
	local previewHeader = grab("Panel.Preview.HeaderLabel", "TextLabel") :: TextLabel?
	local previewSubtitle = grab("Panel.Preview.SubtitleLabel", "TextLabel") :: TextLabel?
	local previewGrid = grab("Panel.Preview.Grid", "GuiObject") :: GuiObject?
	local previewItemTemplate = grab("Panel.Preview.PreviewItemTemplate", "GuiObject") :: GuiObject?
	local previewClose = grab("Panel.Preview.CloseButton", "GuiButton") :: GuiButton?
	local status = grab("Panel.StatusLabel", "TextLabel") :: TextLabel?

	if
		balance == nil
		or catalog == nil
		or itemCardTemplate == nil
		or oddsButton == nil
		or oddsPopup == nil
		or oddsList == nil
		or oddsTemplate == nil
		or preview == nil
		or previewHeader == nil
		or previewSubtitle == nil
		or previewGrid == nil
		or previewItemTemplate == nil
		or previewClose == nil
		or status == nil
	then
		log.warn(`{SCREEN_NAME} is missing {table.concat(missing, ", ")} -- the shop will not be drawn`)
		return nil
	end

	itemCardTemplate.Visible = false
	oddsTemplate.Visible = false
	previewItemTemplate.Visible = false
	oddsPopup.Visible = false
	preview.Visible = false

	return {
		balance = balance,
		catalog = catalog,
		itemCardTemplate = itemCardTemplate,
		oddsButton = oddsButton,
		oddsPopup = oddsPopup,
		oddsList = oddsList,
		oddsTemplate = oddsTemplate,
		preview = preview,
		previewHeader = previewHeader,
		previewSubtitle = previewSubtitle,
		previewGrid = previewGrid,
		previewItemTemplate = previewItemTemplate,
		previewClose = previewClose,
		status = status,
	}
end

local function bind(ui: Elements)
	ui.status.Text = ""
	buildOdds(ui)
	buildCatalog(ui)

	-- Hover shows the odds; a tap toggles them, for touch, which has no hover.
	ui.oddsButton.MouseEnter:Connect(function()
		ui.oddsPopup.Visible = true
	end)
	ui.oddsButton.MouseLeave:Connect(function()
		ui.oddsPopup.Visible = false
	end)
	ui.oddsButton.Activated:Connect(function()
		ui.oddsPopup.Visible = not ui.oddsPopup.Visible
	end)
	ui.previewClose.Activated:Connect(closePreview)

	paint()
end

--[[
	Bound in a loop for the reason every screen controller here gives:
	PlayerGui is re-cloned on respawn, and a screen resolved once is a
	destroyed tree from the first death onwards (VoteController, attachLoop).
]]
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
		table.clear(cards)
		previewing = nil
		restorePreview = nil
		while playerGui:FindFirstChild("Screens") == screensFolder do
			playerGui.ChildRemoved:Wait()
		end
	end
end

function ShopController.Init() end

function ShopController.Start()
	DataController.observe({ "Cash" }, paint)

	local lastOwned: { [string]: number? } = {}
	DataController.observe({ "Inventory" }, function()
		for _, case in Cosmetics.CASES do
			local count = ownedCount(case.Id)
			local before = lastOwned[case.Id]
			-- A count going up is a purchase landing: say so, then redraw.
			if before ~= nil and count > before then
				setStatus(`BOUGHT {string.upper(case.DisplayName)}! OPEN IT IN YOUR INVENTORY`, STATUS_OK_COLOR)
			end
			lastOwned[case.Id] = count
		end
		paint()
	end)
	DataController.observe({ "Titles" }, paintPreview)

	-- Every open starts on the catalog, with no leftover popup or message.
	UIController.onOpen(SCREEN_NAME, function()
		local ui = screen
		if ui ~= nil then
			closePreview()
			ui.oddsPopup.Visible = false
			ui.status.Text = ""
		end
	end)

	attachLoop()
end

return ShopController
