---------------------------------------------------------------------------
-- Punches (RB / R1): Skate 3's shove - the arm swing it uses on pedestrians -
-- played by the engine (skategm.Punch), and the hit decided by the server.
-- Riding on the ground or on foot; in the air RB stays the grab.
-- A skater who is hit is knocked into a bail (skategm.KnockDown); a player
-- who isn't skating takes damage and is knocked back (sv_punch.lua).
---------------------------------------------------------------------------
local P = SKATEGM_PUNCH
local BTN_RB = 0x0200
local cvPunch = CreateClientConVar("skategm_punch", "1", true, false, "1 = RB (R1) punches while riding on the ground or on foot", 0, 1)

local function CanPunch(state)
	if not state or state == "" then return false end
	return not (state:find("Air", 1, true) or state:find("Wipeout", 1, true) or state:find("Grind", 1, true)
		or state:find("Teleport", 1, true) or state:find("Sleeping", 1, true))
end

local was, nextAt = false, 0

-- someone in front within the punch's (or the board's) reach: another
-- skater's skeleton, otherwise a player's or NPC's body (local space)
function P.TargetInReach(S, from, dir, board)
	local flat = Vector(dir.x, dir.y, 0)
	if flat:LengthSqr() < 0.01 then return false end
	flat:Normalize()
	local fist = from + flat * (board and P.REACH_BOARD or P.REACH)
	local limit = (P.RADIUS + 24) ^ 2
	local me = LocalPlayer()
	local function near(body) return body and body:DistToSqr(fist) < limit and (body - from):Dot(flat) > 0 end
	for _, ply in ipairs(player.GetAll()) do
		if ply ~= me and ply:Alive() then
			local r = S.remote and S.remote[ply]
			local snap = r and r.snaps and r.snaps[#r.snaps]
			local body = snap and snap.P and snap.P.HIPS or S.FromAbs(ply:WorldSpaceCenter())
			if near(body) then return true end
		end
	end
	for _, npc in ipairs(ents.FindByClass("npc_*")) do
		if IsValid(npc) and npc:IsNPC() and near(S.FromAbs(npc:WorldSpaceCenter())) then return true end
	end
	return false
end
hook.Add("Think", "skategm_punch", function()
	local S = SkateGM
	if not (S and S.phase == "on" and S.pose and skategm and skategm.Punch) then was = false return end
	local p = S.pose
	local rb = bit.band(bit.bor(p.padButtons or 0, S.keyboardButtons or 0), BTN_RB) ~= 0
	local pressed = rb and not was
	was = rb
	if not pressed or not cvPunch:GetBool() then return end
	if S.InputBlockWanted and S.InputBlockWanted() then return end
	local now = RealTime()
	if now < nextAt or not CanPunch(p.state) then return end
	local pose = S.P
	local dir = pose and S.Facing and S.Facing(pose)
	local from = pose and (pose.SPINE3 or pose.SPINE2 or pose.HIPS)
	if not (dir and from) then return end
	-- only with someone to hit, in reach in front
	local withBoard0 = S.OnFoot and S.OnFoot(p.state) and P.HoldingBoard(pose) or false
	if not P.TargetInReach(S, from, dir, withBoard0) then return end
	nextAt = now + P.COOLDOWN
	skategm.Punch(P.SWING)
	-- on foot with the board in hand, Skate 3 swings the board instead
	-- (the engine picks that animation itself: SHOVE_OFFB_BRD_SEL_SPACE)
	local withBoard = S.OnFoot and S.OnFoot(p.state) and P.HoldingBoard(pose) or false
	-- the fist (or the board) lands partway through the swing
	timer.Simple(withBoard and P.LAND_BOARD or P.LAND, function()
		if not (S.phase == "on" and S.P) then return end
		local at = S.P.SPINE3 or S.P.SPINE2 or S.P.HIPS
		local facing = S.Facing(S.P) or dir
		local abs = S.ToAbs(at or from)
		net.Start(P.NET)
		net.WriteVector(abs)
		net.WriteVector(facing)
		net.WriteBool(withBoard)
		net.SendToServer()
	end)
end)

-- hit while skating: into a bail, thrown the way the punch went
net.Receive(P.NET_HIT, function()
	local v = net.ReadVector()
	local S = SkateGM
	if S and S.phase == "on" and skategm and skategm.KnockDown then skategm.KnockDown(v.x, v.y, v.z) end
end)
