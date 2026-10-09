dofile("gmock.lua")
util = setmetatable({ TableToJSON = function(t) return t end, JSONToTable = function(t) return t end, TraceLine = function() return { Hit = false } end }, { __index = util })
net = { Start = function() end, WriteString = function() end, SendToServer = function() end, Receive = function() end }
hook = { Add = function() end }
concommand = { Add = function() end }
function IsValid(x) return x ~= nil end
local ME = { EntIndex = function() return 9 end }
function LocalPlayer() return ME end
local players = {}
for i = 1, 3 do players[i] = { Nick = function() return "P" .. i end } end
function Entity(i) return players[i] end
local poses = { [1] = { HIPS = Vector(0, 0, 0) }, [2] = { HIPS = Vector(1000, 0, 0) }, [3] = { HIPS = Vector(0, 2000, 0) } }
local api = { pad = { buttons = 0 }, skating = true }
SkateGM = { API = {
	Freeze = function(on) api.frozen = on end, SetHidden = function(_, on) api.hidden = on end, BlockInput = function(on) api.blocked = on end,
	SetView = function(fn) api.view = fn end, SetWatched = function(p) api.watched = p end, IsSkating = function() return api.skating end,
	Pad = function() return api.pad end, PoseOf = function(p) for i, q in ipairs(players) do if q == p then return poses[i] end end end,
} }
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
local M = SKATEGM_MODES
local SP = dofile("../../addon/skategm/lua/skategm_modes/cl_spectate.lua")
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local mode = M.Register({ id = "spectest", title = "Spec test" })
local function press(b) api.pad = { buttons = b } SP.Think(0.016) api.pad = { buttons = 0 } SP.Think(0.016) end

mode:Spectate({ 1, 2 }, { prefer = 2 })
check("spectating: my skater held, hidden and without input; the camera taken", api.frozen and api.hidden and api.blocked and api.view ~= nil)
check("... watching the one the mode prefers, and they're always drawn", SP.target == 2 and api.watched == players[2])
local v = api.view(nil, nil, 75)
check("a chase camera near them", v and (v.origin - poses[2].HIPS):Length() < 250)
press(SP.B.RIGHT)
check("D-pad right: the next player", SP.target == 1 and api.watched == players[1])
api.pad = { buttons = 0, rx = 1 }
for _ = 1, 30 do SP.Think(0.016) end
api.pad = { buttons = 0 }
check("the right stick turns the camera around them", math.abs(SP.yaw) > 10)
press(SP.B.Y)
check("Y: a free camera", SP.free ~= nil)
local before = SP.free.pos
api.pad = { buttons = 0, ly = 1 }
for _ = 1, 30 do SP.Think(0.016) end
api.pad = { buttons = 0 }
check("... the left stick flies it", (SP.free.pos - before):Length() > 100 and api.view(nil, nil, 75).origin == SP.free.pos)
press(SP.B.Y)
check("Y again: following again", SP.free == nil)
mode:Spectate({ 1, 2 }, { prefer = 2 })
check("the same preference again doesn't pull the camera back", SP.target == 1)
mode:Spectate({ 1, 3 }, { prefer = 3 })
check("a new turn (preferred player changes): follow them", SP.target == 3)
mode:Spectate(nil)
check("stopped: everything handed back", not api.frozen and not api.hidden and not api.blocked and api.view == nil and api.watched == nil)
players[2].GetPos = function() return Vector(1000, 50, 0) end
poses[2] = nil
mode:Spectate({ 1, 2 }, { prefer = 2 })
local v2 = api.view(nil, nil, 75)
check("no pose from them (yet): the camera finds their player instead", v2 and (v2.origin - Vector(1000, 50, 40)):Length() < 250)
players[3].GetPos = nil
poses[3] = nil
local t0 = 100
mode:Spectate({ 3, 1 }, { prefer = 3 })
local realtime = RealTime
RealTime = function() return t0 end
api.view(nil, nil, 75)
RealTime = function() return t0 + 2 end
api.view(nil, nil, 75)
RealTime = realtime
check("nothing to see of them for a while: on to the next one", SP.target == 1)
mode:Spectate(nil)
