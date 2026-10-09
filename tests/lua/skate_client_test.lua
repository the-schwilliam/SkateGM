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
dofile("../../addon/skategm/lua/skategm_skate/sh_skate.lua")
dofile("../../addon/skategm/lua/skategm_skate/cl_skate.lua")
local C = SKATE.client
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local players = { { ent = 1, name = "Ann", letters = 0 }, { ent = 2, name = "Me", letters = 0 } }
local function state(t) t.players = t.players or players t.spot = { 0, 0, 0 } t.yaw = 0 C.OnState(t, 0) end
local function lastSent() return sent[#sent] end
api.info = { total = 100, line = 0 }
state({ phase = "attempt", active = 2 })
api.info = { total = 100, line = 200, trick = "Kickflip", trickT = 1 }
C.Think(1)
api.info = { total = 100, line = 600, trick = "50-50", trickT = 2 }
C.Think(1.1)
api.info = { total = 900, line = 0, trick = "50-50", trickT = 2 }
C.Think(1.2)
check("my go lands: its tricks go to the server", lastSent().cmd == "attempt" and lastSent().landed == true and #lastSent().tricks == 2 and lastSent().tricks[1] == "Kickflip")
state({ phase = "between" })
api.info = { total = 900, line = 0 }
state({ phase = "attempt", active = 2, set = { "Kickflip" } })
api.state = "WipeoutGround"
C.Think(2)
check("bailing my go: not landed", lastSent().landed == false)
api.state = "PhysicsGround"
state({ phase = "attempt", active = 1, set = { "Kickflip" } })
check("someone else's go: I watch them", SKATE.mode.spectating ~= nil and SKATE.mode.spectating[1] == 1)
