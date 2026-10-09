dofile("gmock.lua")
local function check(label, ok) print(string.format("%-66s %s", label, ok and "OK" or "<-- WRONG")) end
hook = { Add = function() end }
net = { Start = function() end, WriteString = function() end, SendToServer = function() end, Receive = function() end }
function IsValid(x) return x ~= nil end
function Entity(i) return { EntIndex = function() return i end } end
ITEMS = { NET = "skategm_items", defs = {}, order = {} }
function ITEMS.Register(def) ITEMS.defs[def.id] = def return def end
ITEMS.client = { Model = function() return nil end }
dofile("../../addon/skategm/lua/skategm_items/cl_items.lua")
local C = ITEMS.client

local function Pose(x, y) return { HIPS = Vector(x, y, 40), TRUCK_FRONT = Vector(x + 10, y, 6), TRUCK_BACK = Vector(x - 10, y, 6) } end
local back = C.Behind(1, Pose(0, 0), 0)
check("standing still at first: behind along the board", math.abs(back.x + 1) < 1e-6)
local worst, last = 0, nil
for i = 1, 120 do
	local t = i / 60
	local jitter = (i % 2 == 0) and 3 or -3
	back = C.Behind(1, Pose(0, 400 * t + jitter), t)
	if last and i > 60 then worst = math.max(worst, math.deg(math.acos(math.min(1, back:Dot(last))))) end
	last = back
end
check("riding along +y with 3-unit hip wobble: ends up behind (-y)", back.y < -0.99)
check("... turning no more than 1 degree a frame once settled", worst < 1)
local turned = {}
for i = 1, 30 do
	local t = 2 + i / 60
	back = C.Behind(1, Pose(400 * (t - 2), 800), t)
	turned[i] = back
end
local step = 0
for i = 2, #turned do step = math.max(step, math.deg(math.acos(math.min(1, turned[i]:Dot(turned[i - 1]))))) end
check("a sharp 90 degree turn: swings round smoothly (under 6 degrees a frame)", step < 6)

local CROWBAR
ITEMS.Register = function(def) CROWBAR = def return def end
dofile("../../addon/skategm/lua/skategm_itemdefs/crowbar.lua")
local fwd = Vector(1, 0, 0)
local function headOf(ang, pos)
	local left = -ang:Right()
	return pos + (ang:Forward() * -16.94 + left * -1.2 + ang:Up() * 1.75) * 4
end
local function gripOf(ang, pos)
	local left = -ang:Right()
	return pos + (ang:Forward() * 13.64 + left * 0.13 + ang:Up() * -0.34) * 4
end
local ang0, pos0, dir0 = CROWBAR.Pose(Vector(0, 0, 40), fwd, 0)
check("crowbar: the head (the model's -X as GMod draws it) points along the swing", (-ang0:Forward()):Dot(dir0) > 0.999)
check("... the grip stays at the shoulder", gripOf(ang0, pos0):Distance(Vector(16, 0, 86)) < 0.01 and gripOf(CROWBAR.Pose(Vector(0, 0, 40), fwd, 0.6)):Distance(Vector(16, 0, 86)) < 0.01)
local h0 = headOf(ang0, pos0)
check("... it starts raised overhead, a little behind", h0.z > 150 and h0.x < 16)
local ang1, pos1 = CROWBAR.Pose(Vector(0, 0, 40), fwd, 0.6)
local h1 = headOf(ang1, pos1)
check("... and comes down in front, near the ground, within reach", h1.x > 90 and h1.x < 140 and h1.z > 0 and h1.z < 50)
local before = { CROWBAR.Pose(Vector(0, 0, 40), fwd, 0.6) }
check("... the claw (the model's +Z) faces the ground at the hit", before[1]:Up().z < -0.3)
check("... and faces forward while overhead", ang0:Up().x > 0.3)
check("... in the plane of the swing (not off to one side)", math.abs(h0.y) < 8 and math.abs(h1.y) < 8)

local GRENADE
ITEMS.Register = function(def) GRENADE = def return def end
util = util or {}
util.TraceLine = function(t)
	if t.endpos.z < 0 and t.start.z >= 0 then
		local f = t.start.z / (t.start.z - t.endpos.z)
		return { Hit = true, HitPos = t.start + (t.endpos - t.start) * f, HitNormal = Vector(0, 0, 1) }
	end
	return { Hit = false }
end
dofile("../../addon/skategm/lua/skategm_itemdefs/grenade.lua")
local path, land = GRENADE.Predict(Vector(0, 0, 40), Vector(1, 0, 0))
check("grenade preview: an arc that lands on the floor ahead", land ~= nil and math.abs(land.z - 2) < 0.01 and land.x > 300 and #path > 10)
local top = 0
for _, p in ipairs(path) do top = math.max(top, p.z) end
check("... rising above the throw point first (the lob)", top > 88 + 50)
local start, vel = GRENADE.Throw(Vector(0, 0, 40), Vector(1, 0, 0))
local g, t, first = { pos = start, vel = vel }, 0, nil
for i = 1, 600 do if GRENADE.Step(g, 1 / 120) then first = g.pos break end end
check("... where the real throw (same start, speed, steps) first lands, within 15 units", first and land:Distance(first) < 15)
