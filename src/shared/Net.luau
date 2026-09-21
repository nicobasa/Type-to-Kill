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
--[[
	WHAT IS *NOT* IN HERE, and why -- this list is the useful half of the file.

	  The match state, the timer, the scores, the vote tallies and the
	  scoreboard are NOT packets. They are the round Replica
	  (Match.REPLICA_TOKEN). A player who joins mid-round needs all five, and an
	  event they were not present for cannot give them any of it
	  (NETWORKING-AND-DATA.md, "which pipe?").

	  Cash, XP and Level are NOT packets. They are profile fields, observed
	  through DataController. A `cashChanged` packet would be a second copy of
	  the truth, and the two would drift the first time one was dropped.

	  Level-ups are NOT a packet. The client sees Level change through its own
	  replica observer and already holds the old value, so it can tell a
	  level-up from a first read with no help from the server.

	  Smoke clouds and thrown grenades are NOT packets. The server creates the
	  instances in Workspace and replication carries them, which is what makes
	  every player agree on where a cloud actually is -- a client that rendered
	  its own from a packet would have vision blocked in a place nobody else's
	  smoke covers.

	  Four-digit codes are NOT in any replica, and are not an attribute on the
	  character either -- both of those reach EVERY client, which handed an
	  exploiter the whole lobby's codes at once. They are a packet
	  (codeVisibility), sent per client and only for the players close enough
	  to read. See CodeService.

	A packet below is here because it is a THING THAT HAPPENED: a button was
	pressed, a grenade went off, a player was eliminated.
]]
return ByteNet.defineNamespace(NAMESPACE, function()
	return {
		--=====================================================================
		-- MATCH FLOW -- client asks, server decides
		--=====================================================================

		--[[
			"I pressed PLAY." No payload: the server already knows who asked,
			and it -- not the client -- decides what PLAY means right now. In
			Free For All that is an immediate spawn; in Team Deathmatch it
			moves the player to the TeamSelect phase; during Voting or
			MapLoading it is refused with a notice. The client greys the button
			out in those states too, but that is presentation, not enforcement.
		]]
		requestPlay = ByteNet.definePacket({
			value = ByteNet.nothing,
		}),

		-- client -> server. `team` is a Match.TeamId; the server re-checks both
		-- that the string names a team and that taking it keeps the sides
		-- within Config.Teams.MaxImbalance, at the moment it is processed.
		requestTeam = ByteNet.definePacket({
			value = ByteNet.struct({ team = ByteNet.string }),
		}),

		-- client -> server. "Put me back in the menu." Leaves the round,
		-- releases the code, frees the team slot.
		requestLeaveMatch = ByteNet.definePacket({
			value = ByteNet.nothing,
		}),

		--=====================================================================
		-- THE CORE MECHANIC
		--=====================================================================

		--[[
			client -> server. The whole game, in one packet.

			`code` is a STRING and must stay one: "0047" is a legal code, and a
			number cannot hold its leading zeros. The client sends only what it
			typed -- never a target, never a player, never a UserId. Working out
			who owns a code is the server's job and the client is not told the
			answer even after the fact (codeResult names the victim only on a
			hit, which the player just earned).
		]]
		submitCode = ByteNet.definePacket({
			value = ByteNet.struct({ code = ByteNet.string }),
		}),

		--[[
			server -> client, in reply to submitCode.

			`reason` is a short tag, not a sentence: "Killed", "NoSuchCode",
			"Friendly", "Self", "Protected", "NotPlaying", "RoundInactive",
			"BadCode", "RateLimited". The client maps it to display text, so
			wording changes need no server deploy -- and the server never spends
			bandwidth on prose.

			cash/experience are the amounts ALREADY granted for this kill, sent
			so the "+10 CASH" toast can name a figure. They are a receipt, not
			an instruction: the grant happened server-side before this was sent,
			and the balance itself arrives through the profile replica.
		]]
		codeResult = ByteNet.definePacket({
			value = ByteNet.struct({
				accepted = ByteNet.bool,
				reason = ByteNet.string,
				targetName = ByteNet.string,
				cash = ByteNet.uint32,
				experience = ByteNet.uint32,
			}),
		}),

		--[[
			server -> client. The codes this client is allowed to SEE right now.

			The complete visible set every time, not a delta: a code missing
			from the list means "stop showing it", which is what makes a player
			walking out of range, dying or leaving all one case on the client
			instead of three. The set is small -- only players within
			Config.Code.VisibleRange -- so resending it is cheaper than the
			bookkeeping a delta would need on both sides.

			THIS PACKET IS WHY CODES ARE NOT AN ATTRIBUTE. An attribute on the
			character replicates to every client, so every client held every
			code in the server and an exploiter could kill the whole lobby from
			one loop. Sent this way, a client is only ever given the codes it
			could already read off its own screen. That is a real bound, and it
			is also the honest limit: a code has to be legible to be typed, so
			the ones you ARE shown cannot be hidden from a determined client.
			The remaining defences are the range above and the submit rate
			limit, not secrecy.

			Includes the recipient's OWN code, so the client can mark it "YOU"
			rather than mistaking it for a target.
		]]
		codeVisibility = ByteNet.definePacket({
			value = ByteNet.array(ByteNet.struct({
				userId = ByteNet.float64,
				code = ByteNet.string,
			})),
		}),

		--[[
			server -> client. "You were eliminated." Drives the killcam and the
			kill card.

			Everything about the killer is denormalised into this packet rather
			than looked up client-side, because by the time the card is drawn
			the killer may already have left the server -- and a card that
			blanks out when they do is worse than no card.

			respawnAt is absolute server time, matching PhaseEndsAt in the round
			replica, so the countdown cannot drift.
		]]
		killed = ByteNet.definePacket({
			value = ByteNet.struct({
				killerUserId = ByteNet.float64,
				killerName = ByteNet.string,
				killerLevel = ByteNet.uint16,
				killerKills = ByteNet.uint16,
				respawnAt = ByteNet.float64,
			}),
		}),

		--=====================================================================
		-- VOTING
		--=====================================================================

		-- client -> server. One active map vote per player; voting again moves
		-- it rather than adding a second.
		voteMap = ByteNet.definePacket({
			value = ByteNet.struct({ mapId = ByteNet.string }),
		}),

		voteMode = ByteNet.definePacket({
			value = ByteNet.struct({ modeId = ByteNet.string }),
		}),

		--=====================================================================
		-- MOVEMENT
		--=====================================================================

		--[[
			client -> server. "I am holding sprint" / "I let go."

			An intent, never a speed. The client never sets WalkSpeed -- the
			server does, after checking this player actually has the stamina to
			back it up, which is what stops `Humanoid.WalkSpeed = 500` from
			being a valid move.
		]]
		setSprinting = ByteNet.definePacket({
			value = ByteNet.struct({ active = ByteNet.bool }),
		}),

		--[[
			server -> client. A CORRECTION, not a stream.

			Both sides run the same stamina arithmetic from the same Config
			constants, so the bar normally needs no help. This is sent only when
			the server's answer differs from what the client would have drawn:
			sprint granted, sprint refused, sprint force-cancelled at zero. Sixty
			packets a second to draw a bar the client can already draw is exactly
			the mistake this design avoids.
		]]
		sprintState = ByteNet.definePacket({
			value = ByteNet.struct({
				active = ByteNet.bool,
				stamina = ByteNet.float32,
			}),
		}),

		--=====================================================================
		-- ITEMS
		--=====================================================================

		-- client -> server. 1-based slot index, bounded by Config.Toolbar.SlotCount.
		selectSlot = ByteNet.definePacket({
			value = ByteNet.struct({ slot = ByteNet.uint8 }),
		}),

		--[[
			client -> server. `direction` is where the player is AIMING, which
			only the client knows -- the server has the character's facing, not
			the camera's. It is normalised and sanity-checked server-side, and
			the grenade is then created, owned and simulated by the server: a
			direction is the most a client gets to contribute.
		]]
		throwItem = ByteNet.definePacket({
			value = ByteNet.struct({
				slot = ByteNet.uint8,
				direction = ByteNet.vec3,
			}),
		}),

		dropItem = ByteNet.definePacket({
			value = ByteNet.struct({ slot = ByteNet.uint8 }),
		}),

		--[[
			server -> client. What is in the toolbar now.

			Sent on spawn and on every change. An empty slot is the empty
			string, so the array is always exactly SlotCount long and the client
			never has to reason about holes -- `#` on a table with embedded nils
			is undefined in Luau (quality-gate.md trap #9), and an array that
			can never contain one is the cheapest way to never meet that.
		]]
		loadout = ByteNet.definePacket({
			value = ByteNet.struct({
				slots = ByteNet.array(ByteNet.string),
				selected = ByteNet.uint8,
			}),
		}),

		--[[
			server -> client. A flashbang went off and this client passed the
			checks the server can make: range, and an unobstructed line to the
			blast.

			The client then applies the one check the server cannot -- whether
			the blast is inside its view cone -- because the server knows where
			the character faces, not where the camera looks. That split is
			honest rather than lax: no server can force a client to render white
			pixels, so the view test gains an exploiter nothing that ignoring
			the packet outright would not already give them. Everything that
			CAN be enforced (who is close enough, who is behind a wall) is.
		]]
		flashDetonated = ByteNet.definePacket({
			value = ByteNet.struct({
				position = ByteNet.vec3,
				-- Inside Config.Flash.CloseRange: blinds regardless of facing,
				-- so the client skips the cone test.
				closeRange = ByteNet.bool,
			}),
		}),

		--=====================================================================
		-- SETTINGS, RESULTS, FEEDBACK
		--=====================================================================

		--[[
			client -> server. A request to persist one boolean preference.
			`key` is validated against a whitelist of setting names server-side;
			an unknown key is dropped, never written, because Settings is a
			replicated profile table and an arbitrary client-chosen key is an
			arbitrary client-chosen shape.
		]]
		setSetting = ByteNet.definePacket({
			value = ByteNet.struct({
				key = ByteNet.string,
				enabled = ByteNet.bool,
			}),
		}),

		--[[
			server -> client, once when a match ends. The itemised receipt
			behind the Cash and XP that were already granted.

			The SERVER builds this summary; the client only draws it. The
			amounts here are a report of writes that have already happened, so
			a client that drops the packet loses a screen, never a reward.
		]]
		rewardSummary = ByteNet.definePacket({
			value = ByteNet.struct({
				-- e.g. "VICTORY", "DEFEAT", "DRAW", "1ST PLACE"
				resultText = ByteNet.string,
				entries = ByteNet.array(ByteNet.struct({
					label = ByteNet.string,
					cash = ByteNet.uint32,
					experience = ByteNet.uint32,
				})),
				totalCash = ByteNet.uint32,
				totalExperience = ByteNet.uint32,
			}),
		}),

		--[[
			server -> client. A one-line transient message: "RED TEAM IS FULL",
			"WAIT FOR THE NEXT ROUND". `kind` ("Info" | "Warn" | "Error") picks
			the colour; the client owns the styling.
		]]
		notice = ByteNet.definePacket({
			value = ByteNet.struct({
				kind = ByteNet.string,
				message = ByteNet.string,
			}),
		}),

		--=====================================================================
		-- DEVELOPER CONSOLE
		--=====================================================================

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
