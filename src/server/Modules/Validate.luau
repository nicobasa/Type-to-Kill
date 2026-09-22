--!strict
--[[
	The shared validation ladder for every "amount" and "item id" a mutating
	service function accepts. CashService, InventoryService and LevelService
	each call in here before touching a byte of profile data -- three
	implementers writing this ladder independently is exactly how you end up
	with three subtly different NaN checks, which is the failure this module
	exists to prevent.

	amount(): none of its rungs are redundant with a caller's static `number`
	annotation -- that annotation is erased at runtime, so a value that
	started life on a remote or the dev console proves nothing about its
	actual shape by the time it gets here. The order matters and mirrors
	DevService.parseValue's ladder: type, then NaN, then +/-infinity, then
	non-integer, then range. `n < 0 or n > max` alone lets NaN straight
	through -- 0/0 fails both comparisons -- so NaN is rejected explicitly,
	before anything that assumes a comparable number (quality-gate.md
	trap #8).

	itemId(): the shape rules exist because Inventory is a Replica-replicated
	{[string]: number} table, and Replica's own constraint is "no gaps in
	numeric tables, no keys that aren't strings or numbers" (ARCHITECTURE.md,
	DataService.luau:38-39). A key that LOOKS like a string but IS numeric --
	because something downstream eventually runs tonumber() on it, the way a
	serializer or a table.concat/split helper might -- can turn Inventory
	into a numeric-keyed table with a gap the moment that key sits next to an
	integer-indexed one. That is not a bug you patch later: the profile is
	already saved with the broken shape by the time anyone notices. Rejecting
	every numeric-coercible id up front makes that shape unreachable BY
	CONSTRUCTION rather than something a later check has to catch.

	The check is tonumber(id) == nil, never a digits-only pattern like
	^%d+$. A regex is the trap, not the fix: "1e5" contains "e", so it FAILS
	^%d+$ and sails straight through -- and tonumber("1e5") is 100000, a real
	numeric key. The same gap swallows "0x10" (-> 16), " 5" / "5 " (-> 5),
	"5.0" (-> 5) and "-1". tonumber() is the actual coercion Luau performs,
	so it is the only check that can't be fooled by an id that merely looks
	safe.

	Deliberately NOT enforced: a charset whitelist. "." is legal in an item
	id even though ReplicaClient keys its OnSet listeners by
	table.concat(path, ".") (ReplicaClient.luau:317,:394), which means
	{"Inventory", "a.b"} and {"Inventory", "a", "b"} collide on the wire.
	That hazard is real but latent -- DataController.observe is built on
	OnChange, not OnSet -- so it is logged as an open risk rather than fixed
	with an unrequested charset rule here.

	No requires, no Init, no Start, no per-player state: every function below
	is a pure total function of its arguments.

	On its home: NOT shared/, because nothing on the client needs it and that
	folder is "only what both sides need" (ARCHITECTURE.md:12) -- putting
	server-only logic in ReplicatedStorage would ship it to every client for
	no benefit. NOT Services/ either: the Loader enrolls by name suffix, so a
	plain module is inert there, but that folder is where lifecycle modules
	live and a reader should not have to check the suffix to know which kind
	they are looking at. Modules/ is to Services/ exactly what client/UI is
	to client/Controllers -- plain helpers, no lifecycle, required directly
	(ARCHITECTURE.md Recipe 3).
]]

local Validate = {}

--[[
	True only for a positive, finite, integer `n` no greater than `max`.
	Every caller passes a MAX_* cap tuned to its own domain (MAX_GRANT,
	MAX_ITEM_GRANT, MAX_EXPERIENCE_GRANT) -- this function does not know or
	care what the number represents, only that it is safe to add.
]]
function Validate.amount(n: number, max: number): boolean
	if type(n) ~= "number" then
		return false
	end
	if n ~= n then
		-- NaN. Every comparison below is false for NaN, so it must be
		-- caught here or it would pass every range check that follows.
		return false
	end
	if n == math.huge or n == -math.huge then
		return false
	end
	if math.floor(n) ~= n then
		return false
	end
	if n <= 0 or n > max then
		return false
	end
	return true
end

--[[
	True only for a well-shaped inventory key: a non-empty string, no more
	than 64 bytes, no leading or trailing whitespace, and not coercible to a
	number by tonumber(). See the header for why each rule exists.
]]
function Validate.itemId(id: string): boolean
	if type(id) ~= "string" then
		return false
	end
	if id == "" or #id > 64 then
		return false
	end
	if string.find(id, "^%s") ~= nil or string.find(id, "%s$") ~= nil then
		return false
	end
	if tonumber(id) ~= nil then
		return false
	end
	return true
end

--[[
	True only for a kill code: EXACTLY `digits` characters, every one of them
	an ASCII digit.

	The pattern is anchored at both ends and quantified exactly -- `^%d+$`
	would accept "12345678", and `%d%d%d%d` unanchored would accept
	"abc1234xyz". Both would then be looked up in the code table, where a
	near-miss quietly matching a real code is the difference between a fair
	kill and a free one.

	Length is checked before the pattern so a megabyte-long string from a
	crafted packet is rejected by an integer comparison rather than by running
	a pattern match over all of it.

	The pattern is BUILT by repetition, not written with a count. Lua patterns
	have no `{n}` quantifier -- `^%d{4}$` is not "four digits", it is "a digit,
	then a literal {, then a 4, then a literal }", which matches nothing and
	would reject every code in the game while looking entirely correct.

	A CODE IS A STRING, ALWAYS. Nothing in this codebase may put a code
	through tonumber(): "0047" and 47 are the same number and different codes,
	and the leading zeros are the whole reason a player can read one off a
	headband at a glance. That is also why this takes a string and has no
	numeric overload to reach for.
]]
-- Built once per distinct `digits`. There is one per ruleset in
-- Config.GameModes (4 and 8 today), so this is a small fixed table, not a
-- cache that grows.
local codePatterns: { [number]: string } = {}

function Validate.code(code: string, digits: number): boolean
	if type(code) ~= "string" then
		return false
	end
	if type(digits) ~= "number" or digits ~= digits or digits < 1 or math.floor(digits) ~= digits then
		return false
	end
	if #code ~= digits then
		return false
	end

	local pattern = codePatterns[digits]
	if pattern == nil then
		pattern = `^{string.rep("%d", digits)}$`
		codePatterns[digits] = pattern
	end

	return string.match(code, pattern) ~= nil
end

return Validate
