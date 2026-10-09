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
dofile("../../addon/skategm/lua/skategm_imposter/sh_imposter.lua")
dofile("../../addon/skategm/lua/skategm_imposter/cl_imposter.lua")
local C = IMPOSTER.client
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local players = { { ent = 1, name = "Ann" }, { ent = 2, name = "Me" }, { ent = 3, name = "Cat" } }
local function state(t) t.players = t.players or players t.spot = { 0, 0, 0 } t.yaw = 0 C.OnState(t, 0) end
local function lastSent() return sent[#sent] end

reading = { false, 12500 }
receivers[IMPOSTER.NET_ROLE]()
check("crew: told the score to hit", C.role and not C.role.imposter and C.role.target == 12500 and said[#said]:find("12,500", 1, true) ~= nil)
reading = { true, 0 }
receivers[IMPOSTER.NET_ROLE]()
check("imposter: told they're the imposter, no score", C.role.imposter and C.role.target == nil and said[#said]:find("IMPOSTER", 1, true) ~= nil)

state({ phase = "turn", active = 2, index = 1, turns = 3 })
api.info = { total = 1000, line = 300 }
C.Think(1)
check("my line going: nothing sent yet", lastSent() == nil or lastSent().cmd ~= "landed")
api.info = { total = 5800, line = 0 }
C.Think(1.1)
check("my line lands: its score (what was banked) goes to the server", lastSent().cmd == "landed" and lastSent().score == 4800 and lastSent().how == "land")
local n = #sent
api.info = { total = 9000, line = 0 }
C.Think(1.2)
check("... only once", #sent == n)

state({ phase = "between", index = 1, turns = 3 })
api.info = { total = 9000, line = 0 }
state({ phase = "turn", active = 2, index = 2, turns = 3 })
api.info = { total = 9000, line = 700 }
api.state = "WipeoutGround"
C.Think(2)
check("bailing ends my line with nothing", lastSent().cmd == "landed" and lastSent().how == "bail" and lastSent().score == 0)
api.state = "PhysicsGround"

state({ phase = "between", index = 2, turns = 3 })
state({ phase = "turn", active = 2, index = 3, turns = 3 })
state({ phase = "finish", active = 2, index = 3, turns = 3 })
api.info = { total = 9000, line = 0 }
C.Think(3)
check("time's up and no line going: the turn ends with no line", lastSent().how == "none")

state({ phase = "turn", active = 1, index = 1, turns = 3 })
api.info = { total = 9000, line = 0 }
n = #sent
api.info = { total = 20000, line = 0 }
C.Think(4)
check("someone else's line: my own score is never sent", #sent == n)

state({ phase = "vote" })
check("the vote: my skater held, its input blocked", api.frozen == true and api.blocked == true)
check("I can vote for everyone but me", #C.Choices(C.state) == 2 and C.Choices(C.state)[1].ent ~= 2)
api.pad = 0x0002
C.Think(5)
api.pad = 0
C.Think(5.1)
api.pad = 0x1000
C.Think(5.2)
check("D-pad down, then A: a vote for the second choice", lastSent().cmd == "vote" and lastSent().target == 3)
state({ phase = "results", result = { imposterName = "Cat", crewWin = true, target = 12500, lines = {} } })
check("results: held no more, input back, the impostor said in chat", api.frozen == false and api.blocked == false and said[#said]:find("Cat was the impostor", 1, true) ~= nil)
state({ phase = "lobby" })
check("back in the lobby: my role is forgotten", C.role == nil)
