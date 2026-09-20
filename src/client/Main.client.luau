--!strict
--[[
	Client entry point.
	Everything else lives in StarterPlayerScripts.Controllers and is loaded here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Replica = require(ReplicatedStorage:WaitForChild("ReplicaClient"))

-- Same rationale as the server bootstrap: turn a cryptic "not a valid member"
-- into the actual cause. On the client these are replicated, so wait rather
-- than fail instantly -- but bound the wait so a genuine misconfiguration
-- surfaces instead of hanging forever.
local controllers = script.Parent:WaitForChild("Controllers", 10)
if controllers == nil then
	error(
		"[Main] StarterPlayerScripts.Controllers never replicated.\n"
			.. "The place is likely out of sync with default.project.json.\n"
			.. "Fix: run `rojo serve`, connect the Rojo plugin in Studio, then Play.",
		0
	)
end

Loader.load({ controllers })

--[[
	ORDERING: this MUST come after Loader.load(), and that is not incidental.

	Replica.RequestData() tells the server to start sending replicas. Any
	replica that arrives before a Replica.OnNew(token, ...) listener exists is
	simply missed -- OnNew does not replay past replicas.

	Controllers register their OnNew listeners in Init(). Loader.load() does not
	return until every Init() has completed, so by this line every listener is
	live. This is exactly the guarantee the Init/Start split buys us, and it is
	why "register in Init, act in Start" is a rule and not a style preference.

	Call it exactly once, from here -- never from a controller.
]]
Replica.RequestData()
