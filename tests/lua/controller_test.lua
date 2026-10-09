dofile("gmock.lua")
do local mt = getmetatable(Vector(0, 0, 0)) local idx = type(mt.__index) == "table" and mt.__index or mt
	idx.Cross = idx.Cross or function(a, b) return Vector(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end end
local sentNet = {}
net = setmetatable({ Receive = function() end, Start = function(n) sentNet[#sentNet + 1] = { name = n } end,
	WriteBool = function(b) sentNet[#sentNet].v = b end, WriteVector = function(v) local e = sentNet[#sentNet] e.vs = e.vs or {} e.vs[#e.vs + 1] = v end, WriteFloat = function(v) local e = sentNet[#sentNet] e.fs = e.fs or {} e.fs[#e.fs + 1] = v end,
	SendToServer = function() end }, { __index = function() return function() end end })
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
concommand = { Add = function() end }
function IsValid(x) return x ~= nil end
MsgC = function() end chat = { AddText = function() end }
function LocalPlayer() return { EntIndex = function() return 1 end } end
function CreateClientConVar(n, d) if n == "skategm_rocket" then d = "1" end return { GetBool = function() return d == "1" end, GetFloat = function() return tonumber(d) or 0 end, GetInt = function() return 0 end, GetString = function() return d end } end
function CurTime() return 0 end
local sounds = 0
sound = { Play = function() sounds = sounds + 1 end }
local particles = 0
ParticleEmitter = function() return { SetPos = function() end, Add = function() particles = particles + 1 return nil end } end
local pushed
skategm = { Push = function(x, y, z) pushed = Vector(x, y, z) return true end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
local function check(label, ok) print(string.format("%-66s %s", label, ok and "OK" or "<-- WRONG")) end
S.phase, S.loadedScale = "on", 1
-- (the skater's bones by the add-on's own names - a test with made-up names
-- is how RB went a whole build doing nothing)
local function has(name) for _, n in ipairs(S.BONES) do if n == name then return true end end return false end
check("the bones used for facing and the rocket are real bone names", has("RIGHTSHOULDER") and has("LEFTSHOULDER") and has("HEAD") and has("TRUCK_FRONT") and has("TRUCK_BACK"))
S.P = { TRUCK_FRONT = Vector(10, 0, 3), TRUCK_BACK = Vector(-10, 0, 3), HEAD = Vector(0, 0, 64),
	RIGHTSHOULDER = Vector(0, -8, 55), LEFTSHOULDER = Vector(0, 8, 55) }
local function pose(lt, rt, buttons, state, vx) return { padLT = lt, padRT = rt, padButtons = buttons, state = state, vel = { (vx or 0) / 0.0254, 0, 0 } } end
S.RocketThink(pose(1, 1, 0x0200, "PhysicsGround", 5), 1, 1 / 60)
check("the old combo (both triggers + RB): no rocket now", pushed == nil and not S.rocketOn)
S.RocketThink(pose(0, 0, 0x0040, "PhysicsGround", 5), 1, 1 / 60)
check("the left stick in: no rocket", pushed == nil)
S.RocketThink(pose(0, 0, 0x0080, "PhysicsGround", 5), 1, 1 / 60)
local mps = pushed and pushed:Length() * 0.0254 * 60
check(string.format("right stick in, riding: pushed forward along the board, %.0f m/s^2", mps or -1), pushed and pushed.x > 0 and math.abs(pushed.y) < 1e-6 and math.abs(mps - 18) < 0.5)
check("  with flames, and everyone told it's lit", particles > 0 and sentNet[#sentNet].name == "skategm_rocket" and sentNet[#sentNet].v == true)
pushed = nil
S.RocketThink(pose(0, 0, 0x0080, "PhysicsGround", -5), 1.05, 1 / 60)
check("riding backwards: the rocket on the tail still pushes toward the nose", pushed and pushed.x > 0)
S.P.TRUCK_FRONT, S.P.TRUCK_BACK = Vector(0, 10, 3), Vector(0, -10, 3)
pushed = nil
S.RocketThink(pose(0, 0, 0x0080, "PhysicsGround", 5), 1.07, 1 / 60)
check("board turned sideways to the motion: pushed along the board", pushed and pushed.y > 0 and math.abs(pushed.x) < 1e-6)
S.P.TRUCK_FRONT, S.P.TRUCK_BACK = Vector(10, 0, 3), Vector(-10, 0, 3)
local tailPos = S.Tail(S.P)
check("the flames come out of the tail end", tailPos and tailPos.x < -10)
pushed = nil
S.RocketThink(pose(0, 0, 0x0080, "PhysicsAir", 5), 1.1, 1 / 60)
check("in the air too", pushed ~= nil)
pushed = nil
S.RocketThink(pose(0, 0, 0x0080, "PhysicsGround", 30.5), 1.2, 1 / 60)
check("at the rocket's top speed (30 m/s): no more push", pushed == nil)
S.RocketThink(pose(0, 0, 0x0080, "WipeoutGround", 5), 1.3, 1 / 60)
check("bailing: rocket off, and everyone told", pushed == nil and sentNet[#sentNet].name == "skategm_rocket" and sentNet[#sentNet].v == false)
-- a metered rocket (1 s of fuel)
local cap = 1
S.RocketFuelCap = function() return cap end
S.fuel, S.fuelLocked, S.fuelUsedAt = nil, nil, nil
local fired = 0
for i = 1, 70 do if S.RocketFuelThink(true, true, 10 + i / 60, 1 / 60) then fired = fired + 1 end end
check("metered (1 s): fires for a second, then cuts out", fired >= 58 and fired <= 61 and S.fuel == 0 and S.fuelLocked)
check("... held down while empty: still nothing", not S.RocketFuelThink(true, true, 11.3, 1 / 60))
S.RocketFuelThink(false, false, 11.32, 1 / 60)
check("... let go: no longer locked, but empty until it refills", not S.fuelLocked and S.fuel == 0)
for i = 1, 60 * 4 do S.RocketFuelThink(false, false, 11.4 + i / 60, 1 / 60) end
check("... a few seconds off the stick: full again", S.fuel == cap)
check("... and it fires again", S.RocketFuelThink(true, true, 16, 1 / 60) and S.fuel < cap)
cap = nil
check("infinite: never runs out", S.RocketFuelThink(true, true, 17, 100) and S.fuel == nil)
-- RB on foot
local n = #sentNet
S.UseThink(pose(0, 0, 0x0200, "PhysicsGround"))
S.UseThink(pose(0, 0, 0, "PhysicsGround"))
check("RB on the board: nothing used", #sentNet == n)
S.UseThink(pose(0, 0, 0x0200, "BipedGround"))
local u = sentNet[#sentNet]
check("RB on foot: use, from the head, facing the way the shoulders say", u.name == "skategm_use" and u.fs[3] == 64 and u.vs[1].x > 0.99)
S.UseThink(pose(0, 0, 0x0200, "BipedGround"))
check("held down: once, not every frame", #sentNet == n + 1)
local tilted = Vector(1, 0, 1):GetNormalized()
local d = S.RocketDirection(tilted, "KnownAir")
check("rocket in the air: pushes the way the thruster points, nose up included", d and math.abs(d.z - tilted.z) < 1e-6 and math.abs(d.x - tilted.x) < 1e-6)
d = S.RocketDirection(tilted, "PhysicsGround")
check("... on the ground: the same", d and math.abs(d.z - tilted.z) < 1e-6)
d = S.RocketDirection(Vector(0, 0, -1), "PhysicsAir")
check("... board pointing straight down in the air: straight down", d and d.z < -0.99)
