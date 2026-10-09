---------------------------------------------------------------------------
-- Punches: the server decides who a skater's punch hits (cl_punch.lua).
-- Another skater is knocked into a bail; a player (or NPC) who isn't skating
-- takes damage and is knocked back.
---------------------------------------------------------------------------
local P = SKATEGM_PUNCH
util.AddNetworkString(P.NET)
util.AddNetworkString(P.NET_HIT)

local cvAllow = CreateConVar("skategm_punch_allow", "0", FCVAR_ARCHIVE, "1 = skaters can punch (RB) other players", 0, 1)
local cvDamage = CreateConVar("skategm_punch_damage", "10", FCVAR_ARCHIVE, "Damage a punch does to someone who isn't skating", 0, 100)
local cvForce = CreateConVar("skategm_punch_force", "400", FCVAR_ARCHIVE, "How hard a punch throws (units per second)", 0, 2000)

local HIT_SOUNDS = { "physics/body/body_medium_impact_hard1.wav", "physics/body/body_medium_impact_hard2.wav", "physics/body/body_medium_impact_hard3.wav",
	"physics/body/body_medium_impact_hard4.wav", "physics/body/body_medium_impact_hard5.wav", "physics/body/body_medium_impact_hard6.wav" }
local MISS_SOUND = "weapons/slam/throw.wav"
local BOARD_SOUNDS = { "physics/wood/wood_plank_impact_hard1.wav", "physics/wood/wood_plank_impact_hard2.wav", "physics/wood/wood_plank_impact_hard3.wav" }

-- where a target's body is: a skater's skeleton, otherwise the entity's centre
local function BodyOf(ent)
	if ent:IsPlayer() and ent.SkateGM and ent.SkateGMHips then return ent.SkateGMHips end
	return ent:WorldSpaceCenter()
end

net.Receive(P.NET, function(_, ply)
	if not (IsValid(ply) and ply.SkateGM and cvAllow:GetBool()) then return end
	local from, dir = net.ReadVector(), net.ReadVector()
	local board = net.ReadBool()
	local now = CurTime()
	if now - (ply.SkateGMPunchAt or -10) < P.COOLDOWN * 0.8 then return end
	ply.SkateGMPunchAt = now
	-- the punch must come from where this skater is
	if not ply.SkateGMHips or ply.SkateGMHips:DistToSqr(from) > 120 * 120 then return end
	dir.z = 0
	if dir:LengthSqr() < 0.01 then return end
	dir:Normalize()
	local fist = from + dir * (board and P.REACH_BOARD or P.REACH)
	local best, bestD
	for _, ent in ipairs(ents.FindInSphere(fist, P.RADIUS + 48)) do
		if ent ~= ply and (ent:IsPlayer() and ent:Alive() or ent:IsNPC()) then
			local body = BodyOf(ent)
			local d = body:Distance(fist)
			-- in front of the puncher, close to the fist
			if d < P.RADIUS + 24 and (body - from):Dot(dir) > 0 and (not bestD or d < bestD) then best, bestD = ent, d end
		end
	end
	local M = SKATEGM_MODES
	if best and M and M.SessionOf and (M.SessionOf(ply) or (best:IsPlayer() and M.SessionOf(best))) then best = nil end
	if best and hook.Run("SkateGMCanPunch", ply, best) == false then best = nil end
	if not best then
		sound.Play(MISS_SOUND, from, 65, math.random(95, 110), 0.6)
		return
	end
	local force = cvForce:GetFloat() * (board and P.BOARD_FORCE or 1)
	local push = dir * force + Vector(0, 0, force * 0.35)
	local at = BodyOf(best)
	if board then
		sound.Play(BOARD_SOUNDS[math.random(#BOARD_SOUNDS)], at, 80, math.random(95, 105), 1)
	end
	sound.Play(HIT_SOUNDS[math.random(#HIT_SOUNDS)], at, 75, math.random(95, 105), 1)
	if best:IsPlayer() and best.SkateGM then
		net.Start(P.NET_HIT)
		net.WriteVector(push)
		net.Send(best)
		hook.Run("SkateGMPunched", best, ply)
		return
	end
	local dmg = DamageInfo()
	dmg:SetDamage(cvDamage:GetFloat() * (board and P.BOARD_DAMAGE or 1))
	dmg:SetDamageType(DMG_CLUB)
	dmg:SetAttacker(ply)
	dmg:SetInflictor(ply)
	dmg:SetDamageForce(push * 40)
	dmg:SetDamagePosition(at)
	best:TakeDamageInfo(dmg)
	if best:IsPlayer() then
		best:SetVelocity(push)
		best:ViewPunch(Angle(-6, math.random(-6, 6), 0))
	elseif best:IsNPC() then
		best:SetVelocity(push)
	end
	hook.Run("SkateGMPunched", best, ply)
end)
