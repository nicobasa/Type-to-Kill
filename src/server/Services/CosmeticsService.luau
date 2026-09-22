--!strict
--[[
	Cases and titles: buying a case with Cash, opening it, and equipping what
	came out.

	THE SERVER DOES ALL OF IT. A client asks to buy, to open, to equip; it
	never names a price, a roll or a title it is owed. The price comes from
	Cosmetics (the shared catalog), the Cash is taken by CashService.trySpend
	(which refuses rather than going negative), and the roll is made here with
	a generator nothing else in the VM can reseed.

	EVERY HANDLER IS ONE SLICE WITH NO YIELD IN IT. Buy is "take the Cash, add
	the case"; open is "take the case, roll, grant". Two packets for the same
	player cannot interleave inside either, so a double-click cannot buy one
	case for the price of two or open one case twice. That is the same
	read-check-write discipline CashService and InventoryService already hold
	(quality-gate.md trap #5).

	WHERE THINGS LIVE in the profile (DataService TEMPLATE):
	  Inventory[caseId]   a count, through InventoryService
	  Titles[titleId]     true, a set of owned titles
	  EquippedTitle       one owned title id, or ""

	The equipped title is also the one thing about this that OTHER players see:
	the profile is private, so KillService copies it into Net.killed via
	getEquippedTitle below.

	Robux purchases are not wired: the Shop shows a Robux button, but there is
	no developer product and no ProcessReceipt yet. When there is, the grant it
	makes is InventoryService.add(player, caseId, 1) -- the same line buyCase
	uses after the Cash is taken.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local CashService = require(script.Parent.CashService)
local Config = require(ReplicatedStorage.Shared.Config)
local Cosmetics = require(ReplicatedStorage.Shared.Cosmetics)
local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)

local log = Log.new("CosmeticsService")

-- One limiter per action, so buying and then opening at once is not refused.
local buyLimit = RateLimiter.new(Config.RateLimit.ShopAction)
local openLimit = RateLimiter.new(Config.RateLimit.ShopAction)
local equipLimit = RateLimiter.new(Config.RateLimit.ShopAction)

--[[
	Its own generator, never math.random: any math.randomseed anywhere in the
	VM would otherwise reshape every roll. A drop rate that something else can
	perturb is not one the odds on the Shop screen can promise.
]]
local random = Random.new()

local CosmeticsService = {}

-- Whether the player owns this title. False while the profile is not loaded.
local function owns(player: Player, titleId: string): boolean
	local data = DataService.getData(player)
	if data == nil then
		return false
	end
	-- The dev console can plant anything at a path, so the value is checked
	-- rather than trusted to be the `true` this service writes.
	return data.Titles[titleId] == true
end

--[[
	The player's equipped title id, or "" -- for other players' eyes (the
	killcam card). Re-checked against ownership and the catalog, so a stale or
	planted value can never show a title the player does not have.
]]
function CosmeticsService.getEquippedTitle(player: Player): string
	local data = DataService.getData(player)
	if data == nil then
		return ""
	end
	local equipped = data.EquippedTitle
	if type(equipped) ~= "string" or Cosmetics.title(equipped) == nil or not owns(player, equipped) then
		return ""
	end
	return equipped
end

local function onBuyCase(player: Player, caseId: string)
	-- First, before any work or logging: the only answer to a flood that
	-- costs less than the flood is to drop it (RateLimiter.luau).
	if not buyLimit.allow(player) then
		return
	end

	local case = Cosmetics.case(caseId)
	if case == nil then
		return
	end

	-- trySpend refuses, without writing, when the balance is short. The price
	-- is the catalog's, never anything the packet said.
	if not CashService.trySpend(player, case.CashPrice) then
		return
	end

	if not InventoryService.add(player, case.Id, 1) then
		-- The Cash is already gone and the case could not be added (the
		-- profile went away mid-slice, or the stack is at its cap). Give the
		-- Cash back rather than keep it for nothing.
		CashService.add(player, case.CashPrice)
		log.warn(`{player.Name} paid for a {case.Id} that could not be added -- refunded`)
	end
end

local function onOpenCase(player: Player, caseId: string)
	if not openLimit.allow(player) then
		return
	end

	local case = Cosmetics.case(caseId)
	if case == nil then
		return
	end

	-- Take the case first. tryRemove is atomic and refuses when there is none,
	-- so this is also the "do they own one?" check.
	if not InventoryService.tryRemove(player, case.Id, 1) then
		return
	end

	local title = Cosmetics.roll(random)
	local duplicate = owns(player, title.Id)
	local refund = 0

	if duplicate then
		local rarity = Cosmetics.rarity(title.Rarity)
		refund = if rarity ~= nil then rarity.DuplicateRefund else 0
		if refund > 0 and not CashService.add(player, refund) then
			refund = 0
		end
	else
		DataService.set(player, { "Titles", title.Id }, true)
	end

	-- A receipt for what was already written, for the reveal animation.
	Net.caseOpened.sendTo({
		caseId = case.Id,
		titleId = title.Id,
		duplicate = duplicate,
		refund = refund,
	}, player)

	log.debug(`{player.Name} opened {case.Id}: {title.Id} ({title.Rarity}){if duplicate then " duplicate" else ""}`)
end

local function onEquipTitle(player: Player, titleId: string)
	if not equipLimit.allow(player) then
		return
	end

	local data = DataService.getData(player)
	if data == nil then
		return
	end

	-- "" unequips. Anything else must be a real title the player owns.
	if titleId ~= "" and (Cosmetics.title(titleId) == nil or not owns(player, titleId)) then
		return
	end
	if data.EquippedTitle == titleId then
		return
	end

	DataService.set(player, { "EquippedTitle" }, titleId)
end

function CosmeticsService.Init()
	Net.buyCase.listen(function(data, player)
		if player ~= nil then
			onBuyCase(player, data.caseId)
		end
	end)

	Net.openCase.listen(function(data, player)
		if player ~= nil then
			onOpenCase(player, data.caseId)
		end
	end)

	Net.equipTitle.listen(function(data, player)
		if player ~= nil then
			onEquipTitle(player, data.titleId)
		end
	end)
end

function CosmeticsService.Start()
	log.info(`ready ({#Cosmetics.TITLES} titles, {#Cosmetics.CASES} case(s))`)
end

return CosmeticsService
