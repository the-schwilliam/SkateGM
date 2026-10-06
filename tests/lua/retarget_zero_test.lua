dofile("gmock.lua")
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local T = SkateGM.test
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end

local names = { [0] = "Pelvis", "Spine", "R_Thigh", "R_Calf", "R_Foot", "L_Thigh", "L_Calf", "L_Foot", "Spine1", "Spine2", "Spine4" }
local parent = { [0] = -1, 0, 0, 2, 3, 0, 5, 6, 1, 8, 9 }
local COUNT = 11
local P = {
	HIPS = Vector(100, 200, 30), SPINE = Vector(100, 201, 35), SPINE1 = Vector(100, 203, 44), SPINE3 = Vector(100, 205, 50),
	RIGHTUPLEG = Vector(104, 200, 28), LEFTUPLEG = Vector(96, 200, 28),
	RIGHTLEG = Vector(104, 212, 16), RIGHTFOOT = Vector(104, 204, 2),
	LEFTLEG = Vector(96, 196, 15), LEFTFOOT = Vector(96, 198, 1),
}

local function pose(nudge)
	local pos = { [0] = Vector(0, 0, 40), Vector(0, 0, 44), Vector(0, -4, 38), Vector(0, -4, 20), Vector(0, -4, 3), Vector(0, 4, 38), Vector(0, 4, 20), Vector(0, 4, 3),
		Vector(0, 0, 44) + nudge, Vector(0, 0, 44) - nudge, Vector(0, 0, 56) }
	local W = {}
	for i = 0, COUNT - 1 do local m = Matrix() m:SetTranslation(pos[i]) W[i] = m end
	local set = {}
	local ent = {
		GetModel = function() return "models/zero.mdl" end,
		GetPos = function() return Vector(0, 0, 0) end, GetAngles = function() return Angle(0, 0, 0) end, GetModelScale = function() return 1 end,
		GetBoneName = function(_, i) return "ValveBiped.Bip01_" .. names[i] end,
		BoneHasFlag = function(_, _, f) return f ~= 4 end,
		LookupBone = function(_, n) for i = 0, COUNT - 1 do if "ValveBiped.Bip01_" .. names[i] == n then return i end end end,
		GetBoneParent = function(_, i) return parent[i] end, GetBoneCount = function() return COUNT end,
		GetBoneMatrix = function(_, i) return Matrix(W[i]) end, SetBoneMatrix = function(_, i, m) set[i] = m end,
		Sk8Rig = {}, Sk8P = P,
	}
	T.Retarget(ent)
	return set
end

local a = pose(Vector(0.001, 0, 0))
local b = pose(Vector(0, -0.001, 0.0005))
local worst = 0
for i = 0, COUNT - 1 do worst = math.max(worst, (a[i]:GetTranslation() - b[i]:GetTranslation()):Length()) end
check("spine bones of zero length (Spine1, Spine2 on Spine): the torso doesn't flip with float noise", worst < 0.05)
local dir = (a[10]:GetTranslation() - a[1]:GetTranslation()):GetNormalized()
check("... it still leans the way the skater's spine does", dir:Dot((P.SPINE3 - P.SPINE):GetNormalized()) > 0.95)
local rig = dofile("../../addon/skategm/lua/skategm/cl_retarget.lua")
local onBoard = { HIPS = Vector(0, 0, 40), LEFTFOOT = Vector(-6, 0, 4), RIGHTFOOT = Vector(6, 0, 4), SKATEBOARD_ROOT = Vector(0, 0, 2) }
check("riding: the model is fitted around the board (feet stay on the deck)", rig.ScaleOrigin(onBoard):Distance(onBoard.SKATEBOARD_ROOT) < 1e-6)
local bailed = { HIPS = Vector(0, 0, 10), LEFTFOOT = Vector(-6, 0, 4), RIGHTFOOT = Vector(6, 0, 4), SKATEBOARD_ROOT = Vector(400, 0, 2) }
check("board rolled away after a bail: fitted around the body instead (no drift)", rig.ScaleOrigin(bailed):Distance(bailed.HIPS) < 1e-6)
local mid = { HIPS = Vector(0, 0, 40), LEFTFOOT = Vector(0, 0, 4), RIGHTFOOT = Vector(0, 0, 4), SKATEBOARD_ROOT = Vector(45, 0, 4) }
local o = rig.ScaleOrigin(mid)
check("... and blended in between (no pop as the board leaves)", o.x > 1 and o.x < 44)
