--!strict
--[[
	Applies an impulse grenade's launch to this player's own character.

	The server decides the launch -- who is caught, which way, how hard
	(GrenadeService.detonateImpulse, Config.Impulse) -- and sends the resulting
	velocity here (Net.impulse). It is applied HERE because this client owns its
	character's physics: a velocity the server wrote into a client-owned
	assembly would be overwritten by this client's next physics step and the
	launch would simply not happen.

	No ragdoll, no loss of control. The humanoid is put into Freefall so the
	floor's grip cannot cancel the launch, and from there it steers through the
	air like any jump. On the ground the launch gets at least
	Config.Impulse.GroundLift of upward speed, because a purely sideways push
	on a grounded humanoid is eaten by friction in a frame; in the air it is
	applied exactly as sent.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)

local player = Players.LocalPlayer

local ImpulseController = {}

local function launch(velocity: Vector3)
	-- A NaN component would put the character somewhere undefined (trap #8).
	if velocity.X ~= velocity.X or velocity.Y ~= velocity.Y or velocity.Z ~= velocity.Z then
		return
	end

	local character = player.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	local root = if humanoid ~= nil then humanoid.RootPart else nil
	if humanoid == nil or root == nil or humanoid.Health <= 0 then
		return
	end

	local applied = velocity
	if humanoid.FloorMaterial ~= Enum.Material.Air and applied.Y < Config.Impulse.GroundLift then
		applied = Vector3.new(applied.X, Config.Impulse.GroundLift, applied.Z)
	end

	humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	root.AssemblyLinearVelocity = applied
end

function ImpulseController.Init()
	-- In Init: a blast can land before Start has run, and a packet with no
	-- listener yet is dropped, not queued.
	Net.impulse.listen(function(data)
		launch(data.velocity)
	end)
end

function ImpulseController.Start() end

return ImpulseController
