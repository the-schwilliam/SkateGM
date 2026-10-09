dofile("gmock.lua")
SERVER, CLIENT = true, nil
function AddCSLuaFile() end
FCVAR_NONE = 0
function CreateConVar() return { GetBool = function() return false end } end
local clock = 0
function CurTime() return clock end
local groundNormal = Vector(0, 0, 1)
util.TraceLine = function(t) return groundNormal and { Hit = true, HitNormal = groundNormal } or { Hit = false } end
MASK_SOLID = 1
ENT = {}
dofile("../../addon/skategm/lua/entities/skategm_golfboard.lua")
local B = ENT
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local function board(vel, fwd, up)
	local phys = { v = vel, av = Vector(0, 0, 0), motion = true }
	function phys:GetVelocity() return self.v end
	function phys:SetVelocity(v) self.v = v end
	function phys:GetAngleVelocity() return self.av end
	function phys:AddAngleVelocity(d) self.av = self.av + d end
	function phys:IsMotionEnabled() return self.motion end
	local e = setmetatable({ friction = 100 }, { __index = B })
	function e:GetPhysicsObject() return phys end
	function e:GetPos() return Vector(0, 0, 4) end
	function e:GetForward() return fwd or Vector(1, 0, 0) end
	function e:GetUp() return up or Vector(0, 0, 1) end
	function e:NextThink() end
	return e, phys
end
IsValid = function(x) return x ~= nil end
local function run(e, seconds) for _ = 1, math.floor(seconds * 66) do clock = clock + 1 / 66 e:Think() end end
local e, phys = board(Vector(300, 200, 0))
run(e, 1)
check("wheels down: it doesn't slide sideways (the wheels grip)", math.abs(phys.v.y) < 5)
check("... and rolls on along its length, slowed by the grip (300 -> 200 in a second at 100)", math.abs(phys.v.x - 200) < 5)
e, phys = board(Vector(300, 0, 0))
phys.av = Vector(0, 0, 360)
run(e, 1)
check("... a spin dies away on the ground", phys.av:Length() < 5)
e, phys = board(Vector(300, 0, 0), Vector(1, 0, 0), Vector(0, 0, -1))
run(e, 1)
check("upside down: it scrapes to a stop", phys.v:Length() < 1)
groundNormal = nil
e, phys = board(Vector(300, 200, 0))
run(e, 1)
check("in the air: nothing slows it", phys.v.x == 300 and phys.v.y == 200)
