--!strict
--[[
	CollectionService tag names, as constants.

	A tag string is a contract between an instance authored in Studio and the
	code that finds it, and a contract spelled by hand in two different
	programs is one typo away from a map whose spawn points silently do not
	exist. Naming them here means the code side cannot misspell one; the Studio
	side is checked at load, where MapService reports a map that tagged nothing.

	Tags are PascalCase like every other instance-facing name
	(.claude/rules/model-naming-style.md).

	AUTHORING CONTRACT -- what to tag, and what each one must carry:

	  SpawnPointRed / SpawnPointBlue / SpawnPointFFA
	      A BasePart, normally anchored, invisible and CanCollide off. Its
	      CFrame is the spawn pose: position AND facing. A map wants at least
	      one SpawnPointFFA and several of each team tag; MapService warns and
	      falls back to whatever it can find rather than failing to spawn
	      anyone.

	  PickupNode
	      A BasePart marking where an item can appear.
	      Attribute `ItemId` (string): "Flashbang" | "SmokeGrenade". Missing or
	      unknown and the node is skipped with a warning, rather than spawning
	      an item nobody defined.

	  MenuCameraPoint
	      A BasePart whose CFrame is one stop on the main-menu camera rail. The
	      camera eases from one stop to the next, looking along the part's
	      LookVector.
	      Attribute `Order` (number, optional): sort key. Points with no Order
	      sort by name after the ordered ones, so naming them CameraPoint1,
	      CameraPoint2 ... works with no attributes at all.
]]

local Tags = {}

Tags.SPAWN_RED = "SpawnPointRed"
Tags.SPAWN_BLUE = "SpawnPointBlue"
Tags.SPAWN_FFA = "SpawnPointFFA"
Tags.PICKUP_NODE = "PickupNode"
Tags.MENU_CAMERA_POINT = "MenuCameraPoint"

--[[ Attribute names read off the tagged instances above. ]]
Tags.ATTRIBUTE_ITEM_ID = "ItemId"
Tags.ATTRIBUTE_ORDER = "Order"

return Tags
