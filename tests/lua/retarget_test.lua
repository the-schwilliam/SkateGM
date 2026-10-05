dofile("gmock.lua")
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
local T = S.test

local names = { [0] = "Pelvis", "Spine", "R_Thigh", "R_Calf", "R_Foot", "L_Thigh", "L_Calf", "L_Foot", "Spine1", "Spine2", "Anim_Attachment_RH" }
local parent = { [0] = -1, 0, 0, 2, 3, 0, 5, 6, 1, 8, 3 }
local pos = { [0] = Vector(0, 0, 40), Vector(0, 0, 44), Vector(0, -4, 38), Vector(0, -4, 20), Vector(0, -4, 3), Vector(0, 4, 38), Vector(0, 4, 20), Vector(0, 4, 3),
	Vector(0, 0, 50), Vector(0, 0, 56), Vector(2, -5, 22) }
local COUNT = 11
local W = {}
math.randomseed(3)
for i = 0, COUNT - 1 do
	local m = Matrix()
	m:SetAngles(Angle(math.random(-30, 30), math.random(-30, 30), math.random(-30, 30)))
	m:SetTranslation(pos[i])
	W[i] = m
end
local set, procedural = {}, {}
local ent = {
	GetModel = function() return "models/test.mdl" end,
	GetPos = function() return Vector(0, 0, 0) end,
	GetAngles = function() return Angle(0, 0, 0) end,
	GetModelScale = function() return 1 end,
	GetBoneName = function(_, i) return "ValveBiped.Bip01_" .. names[i] end,
	BoneHasFlag = function(_, i, f) if f == 4 then return procedural[i] == true end return true end,
	LookupBone = function(_, n) for i = 0, COUNT - 1 do if "ValveBiped.Bip01_" .. names[i] == n then return i end end end,
	GetBoneParent = function(_, i) return parent[i] end,
	GetBoneCount = function() return COUNT end,
	GetBoneMatrix = function(_, i) return Matrix(W[i]) end,
	SetBoneMatrix = function(_, i, m) set[i] = m end,
	Sk8Rig = {},
}

local P = {
	HIPS = Vector(100, 200, 30), SPINE = Vector(100, 201, 35), SPINE1 = Vector(100, 203, 44), SPINE3 = Vector(100, 205, 50),
	RIGHTUPLEG = Vector(104, 200, 28), LEFTUPLEG = Vector(96, 200, 28),
	RIGHTLEG = Vector(104, 212, 16), RIGHTFOOT = Vector(104, 204, 2),
	LEFTLEG = Vector(96, 196, 15), LEFTFOOT = Vector(96, 198, 1),
}
ent.Sk8P = P
T.Retarget(ent)

local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local function dir(a, b) return (b - a):GetNormalized() end
local g = function(i) return set[i]:GetTranslation() end
check("every bone posed", #set == COUNT - 1 and set[0] ~= nil)
check("hips right axis follows the skater", dir(g(5), g(2)):Dot(dir(P.LEFTUPLEG, P.RIGHTUPLEG)) > 0.999)
check("thigh -> knee", dir(g(2), g(3)):Dot(dir(P.RIGHTUPLEG, P.RIGHTLEG)) > 0.999)
check("shin -> ankle", dir(g(3), g(4)):Dot(dir(P.RIGHTLEG, P.RIGHTFOOT)) > 0.999)
check("left shin -> ankle", dir(g(6), g(7)):Dot(dir(P.LEFTLEG, P.LEFTFOOT)) > 0.999)
check("spine -> spine1", dir(g(1), g(8)):Dot(dir(P.SPINE, P.SPINE1)) > 0.999)
check("bone lengths are the model's own (thigh, shin)", math.abs((g(3) - g(2)):Length() - (pos[3] - pos[2]):Length()) < 1e-3
	and math.abs((g(4) - g(3)):Length() - (pos[4] - pos[3]):Length()) < 1e-3)
local scale = ((pos[6] - pos[5]):Length() + (pos[7] - pos[6]):Length()) / (P.LEFTUPLEG:Distance(P.LEFTLEG) + P.LEFTLEG:Distance(P.LEFTFOOT))
local feet = (g(4) + g(7)) / 2
check("feet land where the skater's feet are (scaled to the model's legs)", (feet - (P.HIPS + ((P.RIGHTFOOT + P.LEFTFOOT) / 2 - P.HIPS) * scale)):Length() < 1e-3)
local lw = W[3]:GetInverse() * W[10]
local ln = set[3]:GetInverse() * set[10]
check("an unmapped bone follows its parent rigidly", (lw:GetTranslation() - ln:GetTranslation()):Length() < 1e-3)
local first = {}
for i = 0, COUNT - 1 do first[i] = g(i) end
for i = 0, COUNT - 1 do W[i] = Matrix(set[i]) end
T.Retarget(ent)
local worst = 0
for i = 0, COUNT - 1 do worst = math.max(worst, (g(i) - first[i]):Length()) end
check("the same pose again gives the same skeleton (bind pose kept from the first frame)", worst < 1e-3)

local before = set[3]:GetInverse() * set[10]
local stale = Matrix(set[10])
stale:SetTranslation(stale:GetTranslation() + Vector(40, -30, 5))
W[10] = stale
procedural[10] = true
T.Retarget(ent)
local after = set[3]:GetInverse() * set[10]
check("a jiggle bone stays on its parent, whatever its old matrix says (no feedback)", (after:GetTranslation() - before:GetTranslation()):Length() < 1e-3)
