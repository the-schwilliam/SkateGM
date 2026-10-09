dofile("gmock.lua")
local sent = {}
util = setmetatable({ TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
net = { Start = function() end, WriteString = function(t) sent[#sent + 1] = t end, SendToServer = function() end, Receive = function() end }
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end, Run = function() end }
concommand = { Add = function() end }
cvars = { AddChangeCallback = function() end }
function GetConVar() return nil end
function CreateConVar(n, d) return { GetBool = function() return d == "1" end } end
FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY = 1, 2, 4
function IsValid(x) return x ~= nil end
chat = { AddText = function() end }
local ME = { EntIndex = function() return 1 end, GetPos = function() return Vector(0, 0, 0) end, EyeAngles = function() return Angle(0, 0, 0) end }
function LocalPlayer() return ME end
local api = { skating = true, head = Vector(0, 0, 0), teleports = {}, starts = 0 }
SkateGM = { API = {
	IsSkating = function() return api.skating end, IsLoading = function() return false end, CanSkate = function() return true end,
	StartSkating = function() api.starts = api.starts + 1 end,
	TeleportTo = function(p, y) api.teleports[#api.teleports + 1] = { p, y } return true end,
	Freeze = function(on) api.frozen = on end,
	SkaterPos = function() return api.head + Vector(0, 0, 36) end,
	PoseOf = function() return nil end,
	SetPlayerCollision = function(on) api.collision = on end,
	Say = function(t) api.said = t end,
} }
SERVER, CLIENT = nil, nil
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_snake/sh_snake.lua")
dofile("../../addon/skategm/lua/skategm_snake/cl_snake.lua")
local C = SNAKE.client
local function check(label, ok) print(string.format("%-70s %s", label, ok and "OK" or "<-- WRONG")) end
local function st(phase, extra)
	local t = { phase = phase, host = 1, area = { 0, 0, 0, 1000 }, pellets = { { id = 1, x = 300, y = 0, z = 0 } },
		players = { { ent = 1, name = "Me", slot = 1, playing = true, length = 400, start = { -500, 0, 0 }, yaw = 0 }, { ent = 2, name = "Ann", slot = 2, playing = true, length = 400 } } }
	for k, v in pairs(extra or {}) do t[k] = v end
	return t
end
local function last() return sent[#sent] end

check("Snake shows up in the controller menu's host list", SNAKE.mode.hostDef ~= nil and #SNAKE.mode.hostDef.options == 7 and SNAKE.mode.hostDef.options[1].key == "_start")
C.OnState(st("countdown"), 1)
C.Think(1)
check("countdown: on my own start spot, frozen there", #api.teleports == 1 and api.teleports[1][1].x == -500 and api.frozen == true)
check("... skaters don't collide during Snake", api.collision == false)
C.OnState(st("playing"), 4)
C.Think(4)
check("GO: free to skate", api.frozen == false)
for k = 1, 10 do
	api.head = Vector(-500 + k * 20, 0, 0)
	C.Think(4 + k * 0.05)
end
C.Think(5)
local trail = nil
for _, m in ipairs(sent) do if m.cmd == "trail" then trail = m end end
check("my trail is sampled as I skate and sent", trail and #trail.p >= 9)
check("my own fresh trail (the neck) doesn't knock me out", not C.crashed)
C.OnTrail({ ent = 2, p = { -100, -50, 0, -100, 50, 0 }, len = 400 }, 5)
api.head = Vector(-110, 0, 0)
C.Think(5.1)
api.head = Vector(-99, 0, 0)
C.Think(5.2)
check("crossing someone's tail: out, the server's told whose", C.crashed and last().cmd == "crash" and last().by == 2)

C.crashed = nil
C.OnState(st("countdown"), 10)
C.OnState(st("playing"), 13)
api.head = Vector(300, 10, 0)
C.Think(13.1)
check("skating over an orb eats it", last().cmd == "eat" and last().id == 1)
local n = #sent
C.Think(13.2)
check("... once", #sent == n or sent[#sent].cmd ~= "eat")
api.head = Vector(1100, 0, 0)
C.Think(13.3)
check("leaving the arena: out (the wall)", C.crashed and last().cmd == "crash" and last().wall == true)
C.OnTrail({ ent = 2, p = { 0, 0, 0 }, clear = true, len = 400 }, 14)
check("a cleared trail starts again", #C.trails[2].pts == 1)
check("trails are trimmed to their length", (function()
	C.OnTrail({ ent = 2, p = (function() local t = {} for k = 1, 100 do t[#t + 1] = k * 20 t[#t + 1] = 0 t[#t + 1] = 0 end return t end)(), len = 300 }, 15)
	local pts, len = C.trails[2].pts, 0
	for i = 2, #pts do len = len + math.abs(pts[i][1] - pts[i - 1][1]) end
	return len <= 300 and len >= 280
end)())
check("a hit test only counts at board height", not SNAKE.HitsTrail({ 0, 0, 200 }, { { -10, 0, 0 }, { 10, 0, 0 } }) and SNAKE.HitsTrail({ 0, 5, 10 }, { { -10, 0, 0 }, { 10, 0, 0 } }))
local line = {}
for k = 0, 15 do line[#line + 1] = { k * 20, 0, 0 } end
check("your own older tail knocks you out; the last bit behind you doesn't", SNAKE.HitsTrail({ 10, 3, 0 }, line, SNAKE.NECK) and not SNAKE.HitsTrail({ 295, 3, 0 }, line, SNAKE.NECK))

-- an infinite map: my frame moves a chunk over; the trails kept here move with
-- it (each point once, though the newest one is kept in three places)
C.trails = { [2] = { pts = { { 100, 0, 0 }, { 120, 0, 0 } }, len = 400 } }
local newest = { 50, 5, 0 }
C.trails[1] = { pts = { newest }, len = 400 }
C.queue, C.lastSample = { newest }, newest
C.OnFrameShift(Vector(20000, 0, 0))
check("a frame shift moves the trails kept here (walls stay put in the world)", C.trails[2].pts[1][1] == 100 - 20000 and C.trails[2].pts[2][1] == 120 - 20000)
check("... the newest point moved once, not three times", newest[1] == 50 - 20000 and C.lastSample[1] == 50 - 20000)
