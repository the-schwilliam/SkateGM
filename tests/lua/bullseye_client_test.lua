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
dofile("../../addon/skategm/lua/skategm_bullseye/sh_bullseye.lua")
dofile("../../addon/skategm/lua/skategm_bullseye/cl_bullseye.lua")
local BE = BULLSEYE
local C = BE.client
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local board = Vector(0, 0, 0)
SkateGM.API.PoseOf = function() return { SKATEBOARD_ROOT = board } end
SkateGM.API.OnBoard = function() return api.onBoard ~= false end
local players = { { ent = 1, name = "Ann" }, { ent = 2, name = "Me" } }
local function state(t) t.players = players t.start = { 0, 0, 0 } t.target = { 1000, 0, 0 } t.yaw = 0 C.OnState(t, 0) end
local function lastSent() return sent[#sent] end
state({ phase = "shot", active = 2 })
api.state = "PhysicsGround"
C.Think(1)
api.state = "PhysicsAir"
C.Think(1.05)
api.state = "PhysicsGround"
C.Think(1.1)
check("a tiny hop (under a quarter second of air) doesn't count", lastSent() == nil or lastSent().cmd ~= "landed")
api.state = "KnownAir"
board = Vector(100, 0, 0)
C.Think(1.5)
C.Think(2.1)
api.state = "PhysicsGround"
board = Vector(300, 0, 0)
C.Think(2.2)
check("a drop-in on the way (landing nowhere near the rings): the go carries on", lastSent() == nil or lastSent().cmd ~= "landed")
api.state = "KnownAir"
board = Vector(500, 0, 0)
C.Think(2.3)
C.Think(2.9)
api.state = "PhysicsGround"
board = Vector(1060, 5, 6)
C.Think(3.0)
check("a jump from outside the rings, down in them: the board's spot is locked in and sent", lastSent().cmd == "landed" and lastSent().pos[1] == 1060 and api.frozen == true)
local n = #sent
C.Think(3.2)
check("... once", #sent == n)
state({ phase = "between" })
state({ phase = "shot", active = 2 })
api.state = "KnownAir"
C.Think(4)
api.state = "WipeoutGround"
C.Think(4.5)
check("a bail: no score (sent as bailed)", lastSent().bailed == true)
state({ phase = "shot", active = 1 })
check("someone else's jump: I watch them", BE.mode.spectating ~= nil and BE.mode.spectating[1] == 1)
state({ phase = "between" })
state({ phase = "shot", active = 2 })
board = Vector(1000, 0, 0)
api.state = "PhysicsGround" C.Think(10)
api.state = "KnownAir" C.Think(10.1) C.Think(10.6)
api.state = "PhysicsGround" board = Vector(1010, 0, 0) C.Think(10.7)
check("riding into the rings and hopping there: doesn't count (take off from outside)", lastSent().cmd ~= "landed" or lastSent().pos == nil or lastSent().pos[1] ~= 1010)
local function zoned(t) t.width, t.zone = 72, 128 state(t) end
zoned({ phase = "between" })
zoned({ phase = "shot", active = 2 })
sent = {}
board = Vector(1000 - 350, 0, 0)
api.state = "KnownAir" C.Think(20)
check("flying over the no-zone: fine", lastSent() == nil)
zoned({ phase = "between" })
zoned({ phase = "shot", active = 2 })
api.state = "PhysicsGround" C.Think(21)
check("rolling on the no-zone: the go is over, no points", lastSent() and lastSent().cmd == "landed" and lastSent().nozone == true)
check("touched: the no-zone is past the rings, inside its width, near the target's height", BE.InZone({ 1000, 0, 0 }, 72, 128, 650, 0, 0)
	and not BE.InZone({ 1000, 0, 0 }, 72, 128, 1100, 0, 0) and not BE.InZone({ 1000, 0, 0 }, 72, 128, 500, 0, 0) and not BE.InZone({ 1000, 0, 0 }, 72, 128, 650, 0, 300)
	and not BE.InZone({ 1000, 0, 0 }, 72, 0, 650, 0, 0))
