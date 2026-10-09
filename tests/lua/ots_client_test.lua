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
	ScoreInfo = function() return { total = api.banked or 0 } end,
	PoseOf = function(ply) if ply == ANN then return { HIPS = Vector(500, 0, 40) } end end,
	Say = function() end,
} }
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_ots/sh_ots.lua")
dofile("../../addon/skategm/lua/skategm_ots/cl_ots.lua")
local C = OTS.client
local function check(label, ok) print(string.format("%-62s %s", label, ok and "OK" or "<-- WRONG")) end
local function lastCmd() return sentCmds[#sentCmds] or {} end
local players = { { ent = 1, name = "Ann", best = 0, turns = 0 }, { ent = 2, name = "Me", best = 0, turns = 0 } }
local function st(phase, active, extra)
	local t = { phase = phase, active = active, host = 1, spot = { 100, 200, 0 }, yaw = 45, turn = 30, rounds = 2, round = 1, players = players, timeLeft = 20, live = 0 }
	for k, v in pairs(extra or {}) do t[k] = v end
	return t
end
local now = 10
-- Ann's turn: I'm taking part but not active, and I was skating -> stop, and watch
api.skating = true
C.OnState(st("prep", 1), now)
check("someone else's turn: I watch them (spectating, not stopped)", api.stops == 0 and OTS.mode.spectating ~= nil)
C.OnState(st("turn", 1), now)
local watched = false
for _, e in ipairs(OTS.mode.spectating or {}) do if e == 1 then watched = true end end
check("the active skater is the one I can watch", watched)
-- my turn
api.skating = false
C.OnState(st("prep", 2), now)
check("my turn: no more watching", OTS.mode.spectating == nil)
check("my turn: Skate 3 mode switches on", api.starts == 1)
C.Think(now)
check("not teleported until skating", #api.teleports == 0)
api.skating = true
C.Think(now)
check("skating: to the spot, facing its direction", #api.teleports == 1 and api.teleports[1][1].x == 100 and api.teleports[1][2] == 45)
C.Think(now + 0.2)
check("ready not sent too early", lastCmd().cmd ~= "ready")
C.Think(now + 0.7)
check("then ready", lastCmd().cmd == "ready")
check("no camera override on my own turn", C.View(now) == nil)
api.score = 5000
C.OnState(st("turn", 2), now + 4)
check("GO: fresh start at the spot, score counted from here", #api.teleports >= 2 and api.teleports[#api.teleports][1].x == 100 and C.baseline == 5000)
api.score = 7400
C.Think(now + 5)
check("live score is only what I earned this turn", lastCmd().cmd == "live" and lastCmd().score == 2400)
api.score = 8000
C.Think(now + 5.1) -- throttled
C.OnState(st("between", 0, { last = { name = "Me", score = 2400 } }), now + 6)
check("turn over: final score sent (the newest, 3000, not the last live 2400)", lastCmd().cmd == "final" and lastCmd().score == 3000)
-- chat
ran = {}
C.Chat("!ots time 60")
C.Chat("!OTS Start")
check("!ots chat commands become console commands", ran[1] == "skategm_ots_time 60" and ran[2] == "skategm_ots_start")
check("other chat is left alone", C.Chat("hello !ots") == false)
-- the display draws in every phase
draw = { SimpleText = function() end }
surface = setmetatable({}, { __index = function() return function() end end })
TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP = 0, 1, 3
function ScrH() return 1080 end
local okAll = true
for _, ph in ipairs({ "lobby", "prep", "countdown", "turn", "between", "final" }) do
	C.OnState(st(ph, 1, { last = { name = "Ann", score = 10 }, winner = { name = "Ann", score = 10 } }), now)
	local ok, err = pcall(C.Paint, 1920, 1080, now)
	if not ok then okAll = false print("  " .. ph .. ": " .. tostring(err)) end
end
check("display draws in every phase", okAll)

-- held still at the spot through the countdown; a bail has to be real
local frozen = {}
SkateGM.API.Freeze = function(on, why) frozen[why or "mode"] = on or nil end
SkateGM.API.State = function() return api.state end
api.skating, api.state = true, "PhysicsGround"
C.OnState(st("prep", 2), 50)
C.Think(50) C.Think(50.7)
C.OnState(st("countdown", 2), 51)
C.Think(51.1)
check("countdown: held still at the spot", frozen.ots_hold == true)
C.OnState(st("turn", 2, { bailEnds = true }), 54)
C.Think(54.05)
check("GO: let go", frozen.ots_hold == nil)
sentCmds = {}
api.state = "WipeoutGround"
C.Think(54.2) C.Think(54.6)
local bailed = false
for _, m in ipairs(sentCmds) do if m.cmd == "bailed" then bailed = true end end
check("a wipeout in the turn's first second: not a bail", not bailed)
api.state = "PhysicsGround"
C.Think(56)
api.state = "WipeoutGround"
C.Think(56.1)
for _, m in ipairs(sentCmds) do if m.cmd == "bailed" then bailed = true end end
check("a one-frame wipeout later on: not a bail either", not bailed)
api.score, api.banked = 1500, 1000
C.Think(56.4)
local bailScore
for _, m in ipairs(sentCmds) do if m.cmd == "bailed" then bailed = true bailScore = m.score end end
check("a real one (a quarter second in it): the turn's bail", bailed)
check("... and the line it bailed out of doesn't count: only the banked points", bailScore == 1000)
api.score, api.banked = 0, 0
local hidden = {}
SkateGM.API.SetHidden = function(why, on) hidden[why] = on or nil end
C.OnState(st("turn", 2), 60)
C.OnState(st("between", 0, { last = { name = "Me", ent = 2, score = 0, reason = "bailed" } }), 61)
check("my turn just ended (a bail): I stay in sight, free to goof off", not hidden.ots and OTS.mode.spectating == nil and not frozen.ots_wait)
C.OnState(st("prep", 1), 64)
check("the next turn starts: out of the way and watching", hidden.ots and OTS.mode.spectating ~= nil)
C.OnState(st("between", 0, { last = { name = "Ann", ent = 1, score = 10 } }), 70)
check("someone else's turn ended: I keep waiting", hidden.ots)
