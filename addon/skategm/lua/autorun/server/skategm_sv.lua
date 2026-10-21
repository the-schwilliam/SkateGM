for _, f in ipairs({ "sound", "hud", "marker", "water", "why", "trace", "board_model", "settings", "replay", "replay_cam", "replay_fx", "replay_export", "infmap", "keyboard", "presentation", "retarget", "retarget_math", "flickit_hud", "boundary", "nametags", "replay_loop", "hud_original", "skate3_music", "rumble", "stream", "cells" }) do AddCSLuaFile("skategm/cl_" .. f .. ".lua") end
AddCSLuaFile("skategm/sh_space.lua")
AddCSLuaFile("skategm/sh_cells.lua")
include("skategm/sh_space.lua")
-- Server half of SkateGM. The skate simulation runs on the client
-- (gm_skategm); the server only hides the real player, keeps it following the
-- skater (so the world around them stays networked), and puts them back on
-- their feet where the skater is when they toggle out.
util.AddNetworkString("skategm_state")
util.AddNetworkString("skategm_pos")
util.AddNetworkString("skategm_pose") -- skater -> server -> everyone else: bone snapshot
util.AddNetworkString("skategm_off")  -- server -> everyone: this player stopped skating
util.AddNetworkString("skategm_rocket") -- skater -> server -> everyone else: rocket on / off
util.AddNetworkString("skategm_use")    -- skater -> server: use what my skater faces (RB on foot)
util.AddNetworkString("skategm_hidden")  -- skater -> server: hide my skater (spectating, replays)
util.AddNetworkString("skategm_inmenu")  -- skater -> server: I'm stopped in a menu (others draw me faded)
util.AddNetworkString("skategm_respawn") -- skater -> server: where's my spawn (LB + X); server -> skater: there
util.AddNetworkString("skategm_model")

local cvAllow = CreateConVar("skategm_allow", "1", bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
	"Who may use Skater mode: 1 = everyone, 0 = admins only", 0, 1)

-- must match skategm_cl.lua: 36 bones x 3 offsets, then one state byte
local POSE_VALUES = 36 * 3
local POSE_BITS = 96 + POSE_VALUES * 16 + 8

local function Allowed(ply)
	return game.SinglePlayer() or ply:IsListenServerHost() or ply:IsAdmin() or cvAllow:GetBool()
end

local function Unstuck(ply, pos)
	local mins, maxs = ply:GetHull()
	for dz = 0, 72, 8 do
		local p = pos + Vector(0, 0, dz)
		local tr = util.TraceHull({ start = p, endpos = p, mins = mins, maxs = maxs, filter = ply, mask = MASK_PLAYERSOLID })
		if not tr.Hit then return p end
	end
	return pos + Vector(0, 0, 16)
end

local function Enter(ply)
	-- (a gamemode can get ready first: the SkateGM gamemode ends spectating)
	hook.Run("SkateGMEnter", ply)
	-- put the weapon away: a held weapon (e.g. the physgun's glow) would keep
	-- drawing where the hidden player is, following the skater around
	local w = ply:GetActiveWeapon()
	ply.SkateGMWeapon = IsValid(w) and w:GetClass() or nil
	ply.SkateGM = true
	ply:SetNW2Bool("SkateGMSkating", true)
	pcall(ply.SetActiveWeapon, ply, NULL)
	ply:SetMoveType(MOVETYPE_NOCLIP) -- follows SetPos without falling or colliding
	ply:SetNoDraw(true)
	ply:SetNotSolid(true)
	ply:DrawShadow(false)
	ply:DrawWorldModel(false)
	ply:SetLocalVelocity(vector_origin)
end

SKATEGM_HIPS_FRESH = 2
function SkateGMSkaterAbs(ply)
	if ply.SkateGM and ply.SkateGMHips and SysTime() - (ply.SkateGMPoseAt or 0) < SKATEGM_HIPS_FRESH then return ply.SkateGMHips end
	return SKATEGM_SPACE.Abs(ply)
end

local function Leave(ply, pos, yaw)
	ply.SkateGM = false
	ply.SkateGMHips, ply.SkateGMPoseAt = nil, nil
	ply:SetNW2Bool("SkateGMSkating", false)
	net.Start("skategm_off")
	net.WriteEntity(ply)
	net.Broadcast()
	ply:SetMoveType(MOVETYPE_WALK)
	ply:SetNoDraw(false)
	ply:SetNotSolid(false)
	ply:DrawShadow(true)
	ply:DrawWorldModel(true)
	if pos then ply:SetPos(Unstuck(ply, SkateGMLocal(ply, pos))) end
	ply:SetLocalVelocity(vector_origin)
	if yaw then ply:SetEyeAngles(Angle(0, yaw, 0)) end
	-- give the weapon back
	local cls = ply.SkateGMWeapon
	ply.SkateGMWeapon = nil
	if cls and ply:Alive() and ply:HasWeapon(cls) then ply:SelectWeapon(cls) end
end

net.Receive("skategm_state", function(_, ply)
	if not IsValid(ply) or not ply:Alive() then return end
	local on = net.ReadBool()
	local pos = Vector(net.ReadFloat(), net.ReadFloat(), net.ReadFloat())
	local yaw = net.ReadFloat()
	if on then
		if not Allowed(ply) then
			ply:ChatPrint("[SkateGM] Only admins can use Skater mode on this server (skategm_allow 0).")
			return
		end
		Enter(ply)
	elseif ply.SkateGM then
		Leave(ply, pos, yaw)
	end
end)

-- Streamed maps (skategm_stream/<map>/): the world is bigger than Source
-- allows, so each player sits in a cell; their client sees positions relative
-- to it (NW2 SkateGMFrame) and sends absolute ones. SkateGMStreamed,
-- SkateGMFrame, SkateGMAbsPos and SkateGMLocal are in skategm/sh_space.lua.

net.Receive("skategm_pos", function(_, ply)
	if not (IsValid(ply) and ply.SkateGM) then return end
	local pos = Vector(net.ReadFloat(), net.ReadFloat(), net.ReadFloat())
	local limit = (InfMap2 or SkateGMStreamed()) and 2 ^ 31 or 65536
	if pos.x == pos.x and pos.y == pos.y and pos.z == pos.z and math.abs(pos.x) < limit and math.abs(pos.y) < limit and math.abs(pos.z) < limit then
		ply:SetPos(SkateGMLocal(ply, pos))
	end
end)

-- relay pose snapshots to everyone else (the skater's own game runs the engine)
net.Receive("skategm_pose", function(len, ply)
	if not (IsValid(ply) and ply.SkateGM) then return end
	if len < POSE_BITS then return end -- one whole snapshot: 3 floats + 108 x 16-bit + state
	local now = SysTime()
	if now - (ply.SkateGMPoseAt or 0) < 1 / 40 then return end -- at most 40 per second
	ply.SkateGMPoseAt = now
	local hx, hy, hz = net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
	if hx ~= hx or hy ~= hy or hz ~= hz then return end -- NaN
	ply.SkateGMHips = Vector(hx, hy, hz) -- where the skater is (checks "use" requests)
	local values = {}
	for i = 1, POSE_VALUES do values[i] = net.ReadInt(16) end
	local state = net.ReadUInt(8)
	net.Start("skategm_pose", true) -- unreliable: a late snapshot is useless, a newer one follows
	net.WriteEntity(ply)
	net.WriteFloat(hx)
	net.WriteFloat(hy)
	net.WriteFloat(hz)
	for i = 1, POSE_VALUES do net.WriteInt(values[i], 16) end
	net.WriteUInt(state, 8)
	net.SendOmit(ply)
end)

hook.Add("EntityKeyValue", "skategm_map_info", function(ent, key, value)
	if key == "skategm_boundary" then SetGlobal2String("SkateGMBoundary", value)
	elseif key == "skategm_title" then SetGlobal2String("SkateGMTitle", value)
	elseif key == "skategm_stream" then SetGlobal2String("SkateGMStream", value) end
end)

hook.Add("PlayerDisconnected", "skategm", function(ply)
	if ply.SkateGM then
		net.Start("skategm_off")
		net.WriteEntity(ply)
		net.Broadcast()
	end
end)

-- never leave anyone stuck invisible
hook.Add("PlayerDeath", "skategm", function(ply) if ply.SkateGM then Leave(ply) end end)
hook.Add("PlayerSpawn", "skategm", function(ply)
	ply:SetNW2Vector("SkateGMFrame", vector_origin)
	if SKATEGM_CELLS and SKATEGM_CELLS.On() then
		SKATEGM_CELLS.SetCell(ply, vector_origin)
		SKATEGM_CELLS.PlayerShifted(ply)
	end
	if ply.SkateGM then Leave(ply) end
end)
hook.Add("PlayerNoClip", "skategm", function(ply) if ply.SkateGM then return false end end)
hook.Add("PlayerSwitchWeapon", "skategm", function(ply) if ply.SkateGM then return true end end)
hook.Add("PlayerCanPickupWeapon", "skategm", function(ply) if ply.SkateGM then return false end end)
hook.Add("PlayerUse", "skategm", function(ply) if ply.SkateGM then return false end end)
hook.Add("GetFallDamage", "skategm", function(ply) if ply.SkateGM then return 0 end end)
-- invincible while skating: no damage of any kind
hook.Add("EntityTakeDamage", "skategm", function(ent, dmg) if IsValid(ent) and ent:IsPlayer() and ent.SkateGM then return true end end)

-- Public interface for other add-ons and game modes (e.g. skategm_ots).
SkateGM = SkateGM or {}
SkateGM.API = {
	version = 1,
	IsSkating = function(ply) return IsValid(ply) and ply.SkateGM == true end,
	Allowed = function(ply) return IsValid(ply) and Allowed(ply) end,
}


---------------------------------------------------------------------------
-- The rocket board: relay who has it lit, so everyone sees the flames
---------------------------------------------------------------------------
local function RelayRocket(ply)
	if not IsValid(ply) then return end
	ply.SkateGMRocketAt = SysTime()
	local others = {}
	for _, p in ipairs(player.GetAll()) do if p ~= ply then others[#others + 1] = p end end
	net.Start("skategm_rocket")
	net.WriteEntity(ply)
	net.WriteBool(ply.SkateGMRocket == true)
	net.Send(others)
end

-- at most 10 a second, but the latest state always gets through (a quick tap's
-- "off" used to be dropped, and the others saw the rocket lit for good)
net.Receive("skategm_rocket", function(len, ply)
	if not (IsValid(ply) and ply.SkateGM) then return end
	ply.SkateGMRocket = net.ReadBool()
	local wait = 0.1 - (SysTime() - (ply.SkateGMRocketAt or 0))
	if wait <= 0 then return RelayRocket(ply) end
	if ply.SkateGMRocketPending then return end
	ply.SkateGMRocketPending = true
	timer.Simple(wait, function()
		if not IsValid(ply) then return end
		ply.SkateGMRocketPending = nil
		RelayRocket(ply)
	end)
end)

---------------------------------------------------------------------------
-- RB on foot: use what the skater faces (doors, buttons...) as E would. The
-- skater isn't where the player entity is, so the client says where its head
-- is and which way it faces; that has to be where the skater last was.
---------------------------------------------------------------------------
local USE_REACH = 96
-- returns the entity used (or nil) and what to tell the skater
SkateGM.UseFrom = function(ply, from, dir)
	if not (IsValid(ply) and ply.SkateGM) then return nil, "not skating" end
	if not ply.SkateGMHips then return nil, "the server doesn't know where your skater is yet" end
	if from:Distance(ply.SkateGMHips) > 120 then return nil, "that's not where your skater is" end
	if dir:LengthSqr() < 0.25 then return nil, "no direction" end
	dir = dir:GetNormalized()
	local tr = util.TraceLine({ start = from, endpos = from + dir * USE_REACH, filter = ply, mask = MASK_SOLID })
	local ent = tr.Entity
	if not IsValid(ent) or ent:IsPlayer() or ent:IsWorld() then return nil, "nothing to use in reach" end
	-- (straight to the entity: the add-on's own PlayerUse hook keeps skaters'
	-- player entities from using things, which is right for E, not for this)
	ent:Use(ply, ply, USE_ON, 1)
	return ent, "USED " .. string.upper((ent:GetClass() or "it"):gsub("^prop_", ""):gsub("_", " "))
end
net.Receive("skategm_use", function(len, ply)
	if not IsValid(ply) then return end
	local now = SysTime()
	if now - (ply.SkateGMUseAt or 0) < 0.25 then return end
	ply.SkateGMUseAt = now
	local from, dir = Vector(net.ReadFloat(), net.ReadFloat(), net.ReadFloat()), net.ReadVector()
	if from.x ~= from.x or dir.x ~= dir.x then return end
	SkateGM.UseFrom(ply, from, dir)
end)

-- LB + X: back to a spawn point, the one the gamemode would pick. A mode
-- can say no: hook "SkateGMCanRespawn" (ply) returning false.
function SkateGM.SpawnFor(ply)
	local spot = GAMEMODE and GAMEMODE.PlayerSelectSpawn and GAMEMODE:PlayerSelectSpawn(ply, false)
	if not IsValid(spot) then
		for _, class in ipairs({ "info_player_start", "info_player_deathmatch", "info_player_combine", "info_player_rebel", "info_player_terrorist", "info_player_counterterrorist" }) do
			local list = ents.FindByClass(class)
			if #list > 0 then spot = list[math.random(#list)] break end
		end
	end
	if IsValid(spot) then return spot:GetPos(), spot:GetAngles().y end
	return nil
end

net.Receive("skategm_inmenu", function(len, ply)
	if not IsValid(ply) then return end
	ply:SetNW2Bool("SkateGMInMenu", net.ReadBool())
end)

net.Receive("skategm_hidden", function(len, ply)
	if not IsValid(ply) then return end
	ply:SetNW2Bool("SkateGMHidden", net.ReadBool())
end)

-- streamed maps: respawn in the district you're in (its own spawn)
local streamIndex
local function StreamDistricts()
	if streamIndex == nil then
		local txt = file.Read("skategm_stream/" .. game.GetMap() .. "/index.json", "GAME")
		streamIndex = txt and util.JSONToTable(txt) or false
	end
	return streamIndex and streamIndex.districts or nil
end

function SkateGM.StreamRespawn(ply)
	if not SkateGMStreamed() then return end
	local list = StreamDistricts()
	local at = SkateGMSkaterAbs(ply)
	local best, bestD
	for _, d in ipairs(list or {}) do
		local cx, cy = (d.lo[1] + d.hi[1]) / 2, (d.lo[2] + d.hi[2]) / 2
		local dist = (at.x - cx) ^ 2 + (at.y - cy) ^ 2
		if not bestD or dist < bestD then best, bestD = d, dist end
	end
	if best and best.spawn then return Vector(best.spawn[1], best.spawn[2], best.spawn[3]), best.heading or 0 end
end

net.Receive("skategm_respawn", function(len, ply)
	if not IsValid(ply) then return end
	local now = SysTime()
	if now - (ply.SkateGMRespawnAt or 0) < 1 then return end
	ply.SkateGMRespawnAt = now
	if hook.Run("SkateGMCanRespawn", ply) == false then return end
	local pos, yaw = hook.Run("SkateGMRespawnPoint", ply)
	if not pos then pos, yaw = SkateGM.StreamRespawn(ply) end
	if not pos then pos, yaw = SkateGM.SpawnFor(ply) end
	if not pos then return end
	net.Start("skategm_respawn")
		net.WriteFloat(pos.x) net.WriteFloat(pos.y) net.WriteFloat(pos.z) net.WriteFloat(yaw)
	net.Send(ply)
end)

function SkateGM.ApplyPlayerModel(ply, now)
	if not IsValid(ply) or not ply.SkateGM then return false end
	if now < (ply.SkateGMModelNext or 0) then return false end
	ply.SkateGMModelNext = now + 0.5
	local ok = player_manager and player_manager.RunClass and pcall(player_manager.RunClass, ply, "SetModel")
	if not ok and GAMEMODE then hook.Call("PlayerSetModel", GAMEMODE, ply) end
	local col = ply:GetInfo("cl_playercolor")
	if col and col ~= "" then ply:SetPlayerColor(Vector(col)) end
	if ply.SetupHands then ply:SetupHands() end
	return true
end

net.Receive("skategm_model", function(_, ply)
	SkateGM.ApplyPlayerModel(ply, CurTime())
end)
include("skategm/sv_infmap.lua")
include("skategm/sh_cells.lua")
include("skategm/sv_cells.lua")
include("skategm/sv_wheels.lua")

util.AddNetworkString("skategm_admin_cvar")
net.Receive("skategm_admin_cvar", function(len, ply)
	if not IsValid(ply) or not (ply:IsAdmin() or (ply.IsListenServerHost and ply:IsListenServerHost())) then return end
	local name, value = net.ReadString(), net.ReadString()
	if name:sub(1, 8) ~= "skategm_" or #value > 64 then return end
	local c = GetConVar(name)
	if not c or not c:IsFlagSet(FCVAR_REPLICATED) then return end
	c:SetString(value)
end)
