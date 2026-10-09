dofile("gmock.lua")
local sent, receivers = {}, {}
util = setmetatable({ TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
local reading = {}
net = { Start = function() end, WriteString = function(t) sent[#sent + 1] = t end, SendToServer = function() end,
	Receive = function(n, f) receivers[n] = f end, ReadBool = function() return table.remove(reading, 1) end, ReadUInt = function() return table.remove(reading, 1) end }
hook = { Add = function() end }
concommand = { Add = function() end }
function IsValid(x) return x ~= nil end
local said = {}
chat = { AddText = function(...) local t = { ... } said[#said + 1] = t[#t] end }
local ME = { EntIndex = function() return 2 end, GetPos = function() return Vector(0, 0, 0) end, EyeAngles = function() return { y = 0 } end }
function LocalPlayer() return ME end
function Entity() return nil end
local api = { skating = true, info = { total = 1000, line = 0 }, state = "PhysicsGround", pad = 0, frozen = nil, blocked = nil }
SkateGM = { API = {
	IsSkating = function() return api.skating end, IsLoading = function() return false end, CanSkate = function() return true end,
	StartSkating = function() end, TeleportTo = function() return true end, Freeze = function(on) api.frozen = on end,
	BlockInput = function(on) api.blocked = on end, SetHidden = function() end, SetView = function() end,
	IsLocked = function() return true end, ScoreInfo = function() return api.info end, State = function() return api.state end,
	Pad = function() return { buttons = api.pad } end, PoseOf = function() return nil end,
	Say = function(t) said[#said + 1] = t end,
} }
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_boardgolf/sh_boardgolf.lua")
dofile("../../addon/skategm/lua/skategm_boardgolf/cl_boardgolf.lua")
local C = BOARDGOLF.client
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
CONTENTS_SOLID = CONTENTS_SOLID or 1
-- a world: floor at 0, a ceiling at 900, and a wall 600 high across x = 1000
local function solid(p) return p.z < 0 or p.z > 900 or (p.x > 980 and p.x < 1020 and p.z < 600) end
util.PointContents = function(p) return solid(p) and CONTENTS_SOLID or 0 end
util.TraceLine = function(t)
	local a, b = t.start, t.endpos
	for i = 1, 200 do
		local p = a + (b - a) * (i / 200)
		if solid(p) then return { Hit = true, HitPos = p } end
	end
	return { Hit = false }
end
local path = C.FlyPath(Vector(0, 0, 0), Vector(2000, 0, 0))
local blocked, under, over = false, true, true
for i = 1, #path - 1 do if util.TraceLine({ start = path[i], endpos = path[i + 1] }).Hit then blocked = true end end
for _, p in ipairs(path) do
	if p.z > 900 then under = false end
	if p.z < 0 then over = false end
end
check("the flyover's path gets over the wall between the tee and the cup", not blocked)
check("... and stays under the ceiling, above the floor", under and over)
local top = 0
for _, p in ipairs(path) do if math.abs(p.x - 1000) < 200 then top = math.max(top, p.z) end end
check("... it rises over the wall (not through it)", top > 600)
check("... starts near the tee and ends near the cup", path[1].x < 100 and path[#path].x > 1500)
local mid = C.FlyAt(path, 0.5)
check("flying it: a smooth point along the way", mid.x > 500 and mid.x < 1500)
check("the flight's length grows with the hole, within limits", BOARDGOLF.FlyTime(100) == 3.5 and BOARDGOLF.FlyTime(3500) == 5 and BOARDGOLF.FlyTime(99999) == 7)
-- a wall right up to the ceiling across the middle (|y| < 400): no way over it, only round
solid = function(p) return p.z < 0 or p.z > 900 or (p.x > 980 and p.x < 1020 and math.abs(p.y) < 400) end
path = C.FlyPath(Vector(0, 0, 0), Vector(2000, 0, 0))
blocked = false
for i = 1, #path - 1 do if util.TraceLine({ start = path[i], endpos = path[i + 1] }).Hit then blocked = true end end
local wide = 0
for _, p in ipairs(path) do wide = math.max(wide, math.abs(p.y)) end
check("a wall up to the ceiling: the flyover goes round it sideways", not blocked and wide > 400)
check("... and still ends at the cup", path[#path].x > 1500 and math.abs(path[#path].y) < 1)
-- bumpy ground (hills up to 80 every 300 units), no walls
solid = function(p) return p.z < 80 * math.sin(p.x / 300 * math.pi) ^ 2 or p.z > 4000 end
path = C.FlyPath(Vector(0, 0, 0), Vector(3000, 0, 0))
local turns, last = 0, 0
for i = 2, #path do
	local dz = path[i].z - path[i - 1].z
	local sign = dz > 0.5 and 1 or (dz < -0.5 and -1 or 0)
	if sign ~= 0 and last ~= 0 and sign ~= last then turns = turns + 1 end
	if sign ~= 0 then last = sign end
end
check("over bumpy ground: no bobbing up and down every hill (at most one rise and one fall)", turns <= 1)
local low = math.huge
for _, p in ipairs(path) do low = math.min(low, p.z - 80 * math.sin(p.x / 300 * math.pi) ^ 2) end
check("... and never low over the ground", low > 60)
local shortest, longest = math.huge, 0
for i = 2, #path do
	local d = (path[i] - path[i - 1]):Length()
	shortest, longest = math.min(shortest, d), math.max(longest, d)
end
check("an even pace: the path in even steps", longest / shortest < 1.05)
local F = { path = path, cup = Vector(3000, 0, 0) }
local facing = true
for _, k in ipairs({ 0, 0.25, 0.5, 0.75, 1 }) do
	local pos, ang = C.FlyCamera(F, k)
	if ang:Forward():Dot((F.cup - pos):GetNormalized()) < 0.999 then facing = false end
end
check("the camera looks at the cup the whole way", facing)
