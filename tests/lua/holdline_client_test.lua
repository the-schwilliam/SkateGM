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
dofile("../../addon/skategm/lua/skategm_holdline/sh_holdline.lua")
dofile("../../addon/skategm/lua/skategm_holdline/cl_holdline.lua")
local HL = HOLDLINE
local C = HL.client
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local board = Vector(0, 0, 0)
local frozen, hidden, launched, tele = {}, {}, nil, nil
SkateGM.API.PoseOf = function() return { SKATEBOARD_ROOT = board, HIPS = board + Vector(0, 0, 30), TRUCK_FRONT = board + Vector(7, 0, 0), TRUCK_BACK = board - Vector(7, 0, 0) } end
SkateGM.API.Freeze = function(on, why) frozen[why or "mode"] = on or nil end
SkateGM.API.SetHidden = function(why, on) hidden[why] = on or nil end
SkateGM.API.Launch = function(v) launched = v return true end
SkateGM.API.TeleportTo = function(p, y) tele = { p = p, y = y } return true end
SkateGM.API.Score = function() return api.score or 0 end
SkateGM.API.OnBoard = function() return true end
local players = { { ent = 1, name = "Ann", playing = true }, { ent = 2, name = "Me", playing = true } }
local function state(t, at) t.players = players t.start = { 0, 0, 0 } t.yaw = 0 t.turnTime = 10 t.minSpeed = 60 C.OnState(t, at or 0) end
local function lastSent() return sent[#sent] end
local function has(cmd) for _, m in ipairs(sent) do if m.cmd == cmd then return true end end return false end
local nocollide, othersHidden
SkateGM.API.SetPlayerCollision = function(on) nocollide = on == false end
SkateGM.API.HideOthers = function(on) othersHidden = on end
state({ phase = "riding", active = 1, nextUp = 2 }, 1)
check("the line's going: nobody collides, only who I watch is drawn", nocollide == true and othersHidden == true)
check("someone else has the line: I'm out of its way and watching", hidden.holdline and HL.mode.spectating ~= nil)
state({ phase = "handover", active = 2, handover = { pos = { 500, 0, 4 }, yaw = 90, vel = { 0, 200, 0 } } }, 2)
C.Think(2.1)
check("my turn: held exactly where the line is, facing its way", tele and tele.p.x == 500 and tele.y == 90 and frozen.holdline_hold)
check("... and back in sight", not hidden.holdline)
api.state, api.score = "PhysicsGround", 1000
state({ phase = "riding", active = 2, handover = { pos = { 500, 0, 4 }, yaw = 90, vel = { 0, 200, 0 } } }, 5)
C.Think(5.05)
check("go: off at the handed-over speed (in m/s)", launched and math.abs(launched.y - 200 * 0.0254) < 1e-6 and not frozen.holdline_hold)
sent = {}
for i = 1, 60 do board = Vector(500, i * 6, 0) C.Think(5.05 + i * 0.05) end
check("rolling inside my time: where I am goes to the server, no pass yet", has("live") and not has("pass"))
api.state = "KnownAir"
for i = 61, 220 do board = Vector(500, i * 6, 0) C.Think(5.05 + i * 0.05) end
check("my time's up but I'm in the air: wait", not has("pass"))
api.state, api.score = "PhysicsGround", 2500
local level = SkateGM.API.PoseOf
SkateGM.API.PoseOf = function() return { SKATEBOARD_ROOT = board, TRUCK_FRONT = board + Vector(7, 0, 3), TRUCK_BACK = board - Vector(7, 0, 3) } end
board = Vector(500, 1325, 0) C.Think(16.05)
check("rolling, time's up, but on a slope: wait for flat ground", not has("pass"))
SkateGM.API.PoseOf = level
board = Vector(500, 1330, 0) C.Think(16.1)
local m = lastSent()
check("back rolling: the line passes on from here, with my points", m.cmd == "pass" and m.pos[2] > 1300 and m.score == 1500 and math.abs(m.yaw - 90) < 1)
state({ phase = "handover", active = 2 }, 19)
state({ phase = "riding", active = 2 }, 20)
C.Think(20)
sent = {}
api.state = "WipeoutGround"
C.Think(20.5) C.Think(21.6) C.Think(21.95)
check("a real bail (after the first moment): the line's over", has("bail"))
state({ phase = "handover", active = 2 }, 29)
state({ phase = "riding", active = 2 }, 30)
api.state = "PhysicsGround"
sent = {}
for i = 1, 100 do C.Think(30 + i * 0.05) end
check("standing still: the line slowed to a stop", has("stall"))
state({ phase = "results", over = { reason = "stall", name = "Me" }, total = 1500, passes = 1 }, 40)
check("the end: nothing hidden", not hidden.holdline)
