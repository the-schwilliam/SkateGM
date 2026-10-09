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
dofile("../../addon/skategm/lua/skategm_basketboard/sh_basketboard.lua")
dofile("../../addon/skategm/lua/skategm_basketboard/cl_basketboard.lua")
local BB = BASKETBOARD
local C = BB.client
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local pose = { SKATEBOARD_ROOT = Vector(0, 0, 50), HIPS = Vector(0, 0, 60) }
SkateGM.API.PoseOf = function() return pose end
SkateGM.API.OnBoard = function() return api.onBoard ~= false end
local players = { { ent = 1, name = "Ann" }, { ent = 2, name = "Me" } }
local function state(t) t.players = players t.start = { 0, 0, 0 } t.hoop = { 300, 0, 80 } t.radius = 30 t.yaw = 0 C.OnState(t, 0) end
local function lastSent() return sent[#sent] end
local function at(b, hp, t) pose.SKATEBOARD_ROOT, pose.HIPS = b, hp C.Think(t) end
state({ phase = "turn", active = 2 })
api.state = "PhysicsGround"
at(Vector(100, 0, 10), Vector(100, 0, 50), 1)
api.state = "WipeoutGround"
at(Vector(250, 0, 120), Vector(150, 0, 20), 1.2)
check("a bail: no result yet while the board flies", lastSent() == nil or lastSent().cmd ~= "result")
at(Vector(300, 5, 60), Vector(160, 0, 10), 1.4)
check("the board drops through the rim: a basket, straight away", lastSent().cmd == "result" and lastSent().how == "basket")
local n = #sent
at(Vector(300, 5, 2), Vector(165, 0, 10), 6)
check("... once", #sent == n)
state({ phase = "between" })
state({ phase = "turn", active = 2 })
api.state = "PhysicsGround"
at(Vector(250, 0, 120), Vector(250, 0, 130), 10)
at(Vector(300, 0, 60), Vector(300, 0, 70), 10.1)
check("riding down through the hoop with the board: a basket", lastSent().how == "basket")
state({ phase = "between" })
state({ phase = "turn", active = 2 })
api.state = "WipeoutGround"
at(Vector(100, 0, 10), Vector(100, 0, 50), 20)
at(Vector(150, 0, 10), Vector(150, 0, 50), 23)
at(Vector(150, 0, 10), Vector(150, 0, 50), 24.1)
check("a bail that never reaches the hoop: a miss after the watch", lastSent().how == "miss")
state({ phase = "between" })
state({ phase = "turn", active = 2 })
api.state = "WipeoutGround"
at(Vector(0, 0, 10), Vector(0, 0, 50), 30)
at(Vector(290, 0, 10), Vector(290, 0, 120), 30.1)
check("a teleport-sized jump across the rim doesn't count", lastSent().how == "miss")
at(Vector(290, 0, 10), Vector(295, 0, 60), 30.2)
check("... but me falling in afterwards: a point (I'm in)", lastSent().how == "player")
state({ phase = "turn", active = 1 })
check("someone else's turn: I watch them", BB.mode.spectating ~= nil and BB.mode.spectating[1] == 1)
local function zoned(t) t.zone, t.ground = 120, 0 state(t) end
zoned({ phase = "between" })
zoned({ phase = "turn", active = 2 })
api.state = "KnownAir"
at(Vector(250, 0, 60), Vector(250, 0, 100), 40)
at(Vector(240, 0, 60), Vector(240, 0, 100), 40.1)
check("flying over the no-zone: fine", lastSent().how == "player" or lastSent().how ~= "nozone")
api.state = "PhysicsGround"
at(Vector(230, 0, 2), Vector(230, 0, 40), 40.2)
check("rolling on the no-zone under the hoop: the turn's over, no point", lastSent().how == "nozone")
zoned({ phase = "between" })
zoned({ phase = "turn", active = 2 })
api.state = "KnownAir"
at(Vector(300, 5, 120), Vector(300, 0, 130), 50)
at(Vector(300, 5, 60), Vector(300, 0, 70), 50.1)
api.state = "WipeoutGround"
at(Vector(300, 5, 2), Vector(300, 0, 10), 50.2)
check("through the hoop, then landing in the no-zone: the basket counts", lastSent().how == "basket")
local box = {}
C.Box(box, Vector(5, 0, 0), Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1), 2, 3, 4)
local outward = #box == 12 * 9
for t = 1, #box, 9 do
	local a, b, c = Vector(box[t], box[t + 1], box[t + 2]), Vector(box[t + 3], box[t + 4], box[t + 5]), Vector(box[t + 6], box[t + 7], box[t + 8])
	local n = (b - a):Cross(c - a)
	if n:Dot((a + b + c) / 3 - Vector(5, 0, 0)) <= 0 then outward = false end
end
check("the hoop's collision boxes: twelve triangles each, all facing out", outward)
local shape, mesh = C.HoopShape("skategm_hoop:34:40")
check("the hoop's shape (backboard, pole, arm, a ring of rim segments) for the engine, as a mesh", shape and mesh and #shape[1] == (3 + C.RIM_SEGMENTS) * 12 * 9)
local fed = {}
zoned({ phase = "turn", active = 2 })
C.HoopFeed(Vector(0, 0, 0), fed, 0)
check("while the game's played the hoop is fed to the engine where it stands", #fed == 1 and fed[1][1] == "skategm_hoop:30:" .. math.floor(BB.LIFT_DEFAULT) and fed[1][2] == 300)
zoned({ phase = "results" })
fed = {}
C.HoopFeed(Vector(0, 0, 0), fed, 0)
check("... not once it's over", #fed == 0)
