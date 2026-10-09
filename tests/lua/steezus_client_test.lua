dofile("gmock.lua")
local sentCmds = {}
util = setmetatable({ TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
net = { Start = function() end, WriteString = function(t) sentCmds[#sentCmds + 1] = t end, SendToServer = function() end, Receive = function() end }
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
local cmds = {}
concommand = { Add = function(n, f) cmds[n] = f end }
local ran = {}
function RunConsoleCommand(...) ran[#ran + 1] = table.concat({ ... }, " ") end
function IsValid(x) return x ~= nil end
chat = { AddText = function() end }
local ME = { EntIndex = function() return 2 end }
function LocalPlayer() return ME end
local ANN = { EntIndex = function() return 1 end }
function Entity(i) return i == 1 and ANN or (i == 2 and ME or nil) end
function LerpVector(f, a, b) return a + (b - a) * f end
-- the skating add-on's interface
local api = { skating = false, loading = false, score = 0, teleports = {}, starts = 0, stops = 0 }
SkateGM = { API = {
	IsSkating = function() return api.skating end, IsLoading = function() return api.loading end, CanSkate = function() return true end,
	StartSkating = function() api.starts = api.starts + 1 end, StopSkating = function() api.stops = api.stops + 1 api.skating = false end,
	TeleportTo = function(p, y) api.teleports[#api.teleports + 1] = { p, y } return true end,
	Score = function() return api.score end,
	PoseOf = function(ply) if ply == ANN then return { HIPS = Vector(500, 0, 40) } end end,
	Say = function() end,
} }
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_steezus/sh_steezus.lua")
dofile("../../addon/skategm/lua/skategm_steezus/cl_steezus.lua")
local C = STEEZUS.client
local function check(label, ok) print(string.format("%-62s %s", label, ok and "OK" or "<-- WRONG")) end
local function lastCmd() return sentCmds[#sentCmds] or {} end
local players = { { ent = 1, name = "Ann", best = 0, turns = 0 }, { ent = 2, name = "Me", best = 0, turns = 0 } }
local function st(phase, active, extra)
	local t = { phase = phase, active = active, host = 1, spot = { 100, 200, 0 }, yaw = 45, turn = 30, rounds = 2, round = 1, players = players, timeLeft = 20, live = 0 }
	for k, v in pairs(extra or {}) do t[k] = v end
	return t
end
local now = 10
local pose = { christ = false, flip = false }
SkateGM.API.ChristAir = function() return pose.christ end
SkateGM.API.ChristPose = function() return pose.christ or pose.posing end
SkateGM.API.BodyFlip = function() return pose.flip end
SkateGM.API.State = function() return "KnownAir" end
api.skating = true
C.OnState(st("turn", 2), now)
C.Think(now)
C.Think(now + 1)
check("no Christ Air: no points (whatever else I do)", (C.current or 0) == 0)
pose.christ = true
for i = 1, 20 do C.Think(now + 1 + i * 0.05) end
check("one second in the Christ Air pose: 100 points", math.abs(C.current - 100) < 1)
pose.flip = true
for i = 1, 20 do C.Think(now + 2 + i * 0.05) end
check("... while back / front flipping: double, 200 a second", math.abs(C.current - 300) < 1)
pose.christ, pose.flip = false, false
for i = 1, 20 do C.Think(now + 3 + i * 0.05) end
check("... out of the pose: stops", math.abs(C.current - 300) < 1)
pose.posing = true
for i = 1, 8 do C.Think(now + 4 + i * 0.05) end
check("in the pose, the engine hasn't named it yet: nothing yet", math.abs(C.current - 300) < 1)
pose.christ = true
C.Think(now + 4.45)
check("... named a Christ Air: the time held before that counts too (0.4 s: 40)", math.abs(C.current - 340) < 1)
pose.christ, pose.posing = false, false
C.Think(now + 4.5)
