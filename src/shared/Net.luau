--!strict
--[[
	Packet definitions. ONE namespace, required by both sides.

	This is a plain module -- the name doesn't end in Service/Controller, so the
	Loader ignores it (ARCHITECTURE.md, Recipe 3). Require it directly.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local NAMESPACE = "Game"

-- On the CLIENT this require yields until the server has created
-- ReplicatedStorage.BytenetStorage. That's ByteNet's own WaitForChild.
local ByteNet = require(ReplicatedStorage.Packages.ByteNet)

--[[
	Why this guard exists -- do not delete it.

	ByteNet waits for the BytenetStorage *folder*, but looks up the individual
	namespace with FindFirstChild, NOT WaitForChild
	(Packages/_Index/ffrostflame_bytenet@0.4.6/bytenet/src/replicated/values.luau).
	If our namespace's StringValue hasn't replicated yet, access() returns nil and
	defineNamespace immediately indexes it -> "attempt to index nil with 'read'".

	The folder existing does NOT imply our namespace inside it exists. That gap is
	the whole bug, and it only opens on a cold boot (Studio Play, or the first
	player into a fresh server), which is exactly when you'd blame something else.
]]
if RunService:IsClient() then
	local storage = ReplicatedStorage:WaitForChild("BytenetStorage")
	if storage:WaitForChild(NAMESPACE, 10) == nil then
		error(
			`[Net] namespace "{NAMESPACE}" never replicated.\n`
				.. "The server never required Shared.Net, so it never published the packet IDs.\n"
				.. "Fix: require it from any *Service (a require at file scope is enough).",
			0
		)
	end
end

--[[
	devSet/devSnapshot move values as `kind` (a type tag) plus a plain `string`,
	never as ByteNet.unknown. That is the whole point, not a stopgap: the wire
	type itself is then the guarantee. A struct typed {kind: string, value:
	string} can only ever deserialize into two scalars, so there is no encoding
	in which a nested table reaches DevService's validator to begin with --
	parseValue() there still bounds-checks the string, but the wire shape
	already rules out the dangerous shape.

	targetUserId is float64, not uint32 -- uint32 tops out around 4.3 billion,
	which real Roblox UserIds have already exceeded for newer accounts. float64
	represents every UserId Roblox can issue exactly.
]]
return ByteNet.defineNamespace(NAMESPACE, function()
	return {
		-- client -> server
		devRequestSnapshot = ByteNet.definePacket({
			value = ByteNet.struct({ targetUserId = ByteNet.float64 }),
		}),

		-- server -> client
		devSnapshot = ByteNet.definePacket({
			value = ByteNet.struct({
				targetUserId = ByteNet.float64,
				entries = ByteNet.array(ByteNet.struct({
					path = ByteNet.array(ByteNet.string),
					kind = ByteNet.string,
					value = ByteNet.string,
				})),
			}),
		}),

		-- client -> server
		devSet = ByteNet.definePacket({
			value = ByteNet.struct({
				targetUserId = ByteNet.float64,
				path = ByteNet.array(ByteNet.string),
				kind = ByteNet.string,
				value = ByteNet.string,
			}),
		}),

		-- server -> client
		devResult = ByteNet.definePacket({
			value = ByteNet.struct({ ok = ByteNet.bool, message = ByteNet.string }),
		}),

		--[[
			server -> client. "Are you a developer?" -- answered BY the server,
			never computed by the client.

			This packet exists because ConfigService is server-only ("Attempting
			to call its methods from a client script results in an error"), so the
			client physically cannot read the developers list itself. It is not a
			trust boundary: `allowed` only decides whether the console UI is drawn.
			A client that forges it gains a UI and nothing else, because DevService
			re-checks authority on every privileged packet it receives. The client
			was never trusted before either -- it just used to compute the same
			answer locally instead of being told.

			Sent on join, and again to everyone whenever the config changes, which
			is what makes adding a UserId in the dashboard take effect live.
		]]
		devAccess = ByteNet.definePacket({
			value = ByteNet.struct({ allowed = ByteNet.bool }),
		}),

		--[[
			client -> server. "Tell me my access." No payload -- the server only
			needs to know WHO asked, and it gets that for free.

			This exists because a push alone races: the server learns a player
			joined before that player's LocalScripts have run, and a RemoteEvent
			fired at a client with no listener yet is simply dropped, not queued.
			A fresh joiner would silently never get a console. Asking from the
			client's own Start() -- by which point Init() has registered the
			listener -- is the one ordering that cannot lose the reply.
		]]
		devRequestAccess = ByteNet.definePacket({
			value = ByteNet.nothing,
		}),
	}
end)
