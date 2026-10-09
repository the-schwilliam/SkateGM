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
local BG = BOARDGOLF
local C = BG.client
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local board = Vector(0, 0, 0)
local tele, hidden, collide, view = nil, {}, "own", nil
local frozen = {}
local function pose()
	return { SKATEBOARD_ROOT = board, HIPS = board + Vector(0, 0, 30),
		TRUCK_FRONT = board + Vector(7, 0, -2), TRUCK_BACK = board + Vector(-7, 0, -2),
		RIGHT_WHEELFRONT = board + Vector(7, -3, -3), LEFT_WHEELFRONT = board + Vector(7, 3, -3),
		RIGHT_WHEELBACK = board + Vector(-7, -3, -3), LEFT_WHEELBACK = board + Vector(-7, 3, -3) }
end
SkateGM.API.PoseOf = function() return pose() end
SkateGM.API.TeleportTo = function(p, yaw) tele = { p = p, yaw = yaw } return true end
SkateGM.API.SetHidden = function(why, on) hidden[why] = on or nil end
SkateGM.API.SetPlayerCollision = function(on) collide = on end
SkateGM.API.Freeze = function(on, why) frozen[why or "mode"] = on or nil end
SkateGM.API.SetView = function(f) view = f end
local BALL = { GetPos = function() return Vector(300, 40, 0) end, GetForward = function() return Vector(1, 0, 0) end }
function Entity(i) if i == 77 then return BALL end if i == 1 then return { EntIndex = function() return 1 end } end end
local players = { { ent = 1, name = "Ann", playing = true }, { ent = 2, name = "Me", playing = true, lie = { 100, 0, 0 }, strokes = 1 } }
local function state(t, at) t.players = players t.tee = { 0, 0, 0 } t.cup = { 100, 500, 0 } t.shotTime = 4 t.radius = 56 C.OnState(t, at or 0) end
local function lastSent() return sent[#sent] end
state({ phase = "prep", active = 2 })
C.Think(1)
check("my shot: to my lie, facing the cup", tele and tele.p.x == 100 and math.abs(tele.yaw - 90) < 0.01)
C.Think(1.7)
check("... then ready", lastSent().cmd == "ready")
state({ phase = "shot", active = 2 }, 2)
for i = 0, 79 do board = Vector(i * 10, 0, 0) C.Think(2 + i * 0.05) end
check("riding inside the shot clock: nothing let go", lastSent().cmd ~= "release")
board = Vector(810, 0, 0) C.Think(6.05)
local m = lastSent()
check("the clock runs out: my board let go as it is (where, which way, how fast)", m.cmd == "release" and m.pos[1] == 810 and math.abs(m.ang[2]) < 0.01 and m.vel[1] > 150)
check("... and I'm out of the picture: unseen, untouchable, frozen", hidden.boardgolf and collide == false and frozen.boardgolf)
state({ phase = "roll", active = 2, board = 77 }, 6.2)
C.Think(6.3)
local v = view and view(nil, nil, 70)
check("the camera follows the ball", v ~= nil and v.angles ~= nil)
state({ phase = "between", last = { name = "Me", result = "lie", strokes = 2, distance = 300 } }, 8)
C.Think(8.1)
check("... through the result", view ~= nil)
state({ phase = "prep", active = 2 }, 11)
C.Think(11.1)
check("next shot: back in the picture, the camera mine again", not hidden.boardgolf and collide == nil and not frozen.boardgolf and view == nil)
state({ phase = "shot", active = 2 }, 20)
api.pad = 0
C.Think(20.1)
local before = #sent
api.pad = 0x2000
board = Vector(50, 0, 0)
C.Think(20.3)
check("B doesn't end the shot (only the shot clock does)", #sent == before or lastSent().cmd ~= "release")
state({ phase = "roll", active = 1, board = 77 }, 30)
C.Think(30.1)
check("someone else's ball: I follow it too", view ~= nil)
state({ phase = "results", winners = { names = { "Me" }, strokes = 2 } }, 40)
C.Think(40.1)
check("the end: nothing left holding me", not hidden.boardgolf and not frozen.boardgolf and not frozen.boardgolf_cam and view == nil)
