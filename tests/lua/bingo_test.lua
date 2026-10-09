dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
SERVER = true
local chats = {}
util = setmetatable({ AddNetworkString = function() end, TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
local states = {}
net = { Start = function() end, WriteString = function(t) states[#states + 1] = t end, Broadcast = function() end, Receive = function() end, ReadString = function() end, Send = function() end, SendToServer = function() end }
hook = { Add = function() end, Run = function() end }
timer = { Simple = function(_, f) f() end }
PrintMessage = function(_, t) chats[#chats + 1] = t end
HUD_PRINTTALK = 3
function IsValid(x) return x ~= nil end
SkateGM = { API = { Allowed = function() return true end, IsSkating = function() return true end } }
local function Player(id, name)
	local p = { id = id, name = name }
	function p:EntIndex() return self.id end
	function p:Nick() return self.name end
	function p:IsAdmin() return false end
	function p:ChatPrint(t) chats[#chats + 1] = t end
	return p
end
math.randomseed(5)
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_bingo/sh_bingo.lua")
dofile("../../addon/skategm/lua/skategm_bingo/sv_bingo.lua")
local G = BINGO.session

local card = BINGO.Deal(math.random, true)
local seen, dup = {}, false
for _, id in ipairs(card) do if seen[id] then dup = true end seen[id] = true end
check("a card: 9 different squares, the middle free", #card == 9 and card[5] == "free" and not dup)
check("three in a row wins (rows, columns, diagonals)", BINGO.Won({ [1] = true, [2] = true, [3] = true }, card) and BINGO.Won({ [3] = true, [7] = true }, card) and BINGO.Won({ [2] = true, [8] = true }, card))
check("two in a row doesn't", not BINGO.Won({ [1] = true, [2] = true }, card))
check("a full card needs every square", not BINGO.Won({ [1] = true, [2] = true, [3] = true }, card, true))

local ann, ben = Player(1, "Ann"), Player(2, "Ben")
local t = 100
BINGO.Command(ann, { cmd = "create", time = 5, full = false, free = true, canSkate = true }, t)
BINGO.Command(ben, { cmd = "join", canSkate = true }, t)
BINGO.Command(ann, { cmd = "begin" }, t)
check("start: the same card for everyone, then a countdown", G.phase == "countdown" and #G.card == 9 and G.time == BINGO.TIME_MIN)
BINGO.Think(t + 3.1)
check("GO", G.phase == "playing")
BINGO.Command(ben, { cmd = "done", cell = 5 }, t + 4)
check("the free square can't be claimed", next(G.entries[ben].marks) == nil)
BINGO.Command(ben, { cmd = "done", cell = 1 }, t + 4)
BINGO.Command(ben, { cmd = "done", cell = 1 }, t + 4.1)
BINGO.Command(ben, { cmd = "done", cell = 99 }, t + 4.2)
local count = 0
for _ in pairs(G.entries[ben].marks) do count = count + 1 end
check("a square ticks once; nonsense squares are ignored", G.entries[ben].marks[1] and count == 1)
BINGO.Command(ben, { cmd = "done", cell = 9 }, t + 5)
check("square 1 + free middle + square 9: BINGO", G.phase == "results" and G.winner and G.winner.name == "Ben")
BINGO.Think(t + 5 + BINGO.RESULTS + 0.1)
check("back to the lobby", G.phase == "lobby")
BINGO.Command(ann, { cmd = "begin" }, t + 30)
BINGO.Think(t + 33.1)
BINGO.Command(ann, { cmd = "done", cell = 2 }, t + 34)
BINGO.Think(t + 33.2 + BINGO.TIME_MIN)
check("time's up: most squares wins", G.phase == "results" and G.winner.name == "Ann")

SERVER, CLIENT = nil, nil
local sent = {}
net.WriteString = function(t) sent[#sent + 1] = t end
local ME = { EntIndex = function() return 1 end }
function LocalPlayer() return ME end
local api = { state = "PhysicsGround", info = { line = 0, multiplier = 1 }, speed = 0 }
SkateGM = { API = {
	IsSkating = function() return true end, IsLoading = function() return false end, CanSkate = function() return true end,
	State = function() return api.state end, ScoreInfo = function() return api.info end, Speed = function() return api.speed end, Say = function() end, OnBoard = function() return api.onBoard ~= false end,
} }
SKATEGM_MODES = nil
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_bingo/sh_bingo.lua")
dofile("../../addon/skategm/lua/skategm_bingo/cl_bingo.lua")
local C = BINGO.client
local testCard = { "kickflip", "fiftyfifty", "air15", "line2k", "free", "mult3", "speed12", "grind2", "clean" }
local function stateWith(phase) return { phase = phase, host = 1, card = testCard, players = { { ent = 1, name = "Ann", marks = {} } } } end
C.OnState(stateWith("countdown"), 1)
C.OnState(stateWith("playing"), 4)
local function frame(now, state, info, speed)
	api.state = state or api.state
	if info then for k, v in pairs(info) do api.info[k] = v end end
	api.speed = speed or api.speed
	C.Track(now)
end
local function done(i) for _, m in ipairs(sent) do if m.cmd == "done" and m.cell == i then return true end end return false end
frame(4.0, "PhysicsGround", { line = 0 })
frame(4.1, "PhysicsAir", { trick = "Varial Kickflip", trickT = 4.1, multiplier = 2 })
frame(4.2, "PhysicsAir")
check("a kickflip in the air: waiting for the landing", not done(1) and C.pending[1])
frame(5.0, "PhysicsGround", { line = 800 })
check("landed: the kickflip square ticks", done(1))
check("... the air was too short for 1.5 s", not done(3))
frame(5.1, "PhysicsAir", { trick = "Kickflip", trickT = 5.1 })
frame(7.0, "WipeoutGround", { line = 800 })
frame(7.5, "PhysicsGround", { line = 0 })
check("a bail: what was pending doesn't count", not done(3))
frame(8.0, "PhysicsAir")
frame(9.8, "PhysicsGround")
frame(10.0, "PhysicsGround", { line = 900, multiplier = 3 })
check("1.8 s of air, landed: ticks", done(3))
check("x3 multiplier on a landed line: ticks", done(6))
frame(10.5, "GrindFiftyFifty")
frame(13.0, "GrindFiftyFifty")
frame(13.1, "PhysicsGround", { line = 2500 })
check("a 50-50 and a 2.5 s grind, landed: both tick", done(2) and done(8))
check("a 2,000 point line: ticks", done(4))
frame(14, nil, nil, 12.5)
check("hitting 12 m/s ticks at once", done(7))
frame(15, nil, { clean = true })
check("a clean landing ticks", done(9))
local n = 0
for _, m in ipairs(sent) do if m.cmd == "done" and m.cell == 1 then n = n + 1 end end
check("each square is sent once", n == 1)
check("Trick Bingo is hostable from the controller menu", BINGO.mode.hostDef ~= nil)
sent = {}
api.info = { line = 0, multiplier = 1, clean = true }
api.speed, api.state = 0, "PhysicsGround"
C.OnState(stateWith("countdown"), 20)
C.OnState(stateWith("playing"), 23)
frame(23.1)
frame(23.2)
check("a new game right after a clean landing: Clean landing doesn't tick by itself", not done(9))
frame(24, nil, { clean = false })
frame(25, nil, { clean = true })
check("... a clean landing in this game does", done(9))
api.onBoard = false
frame(26, "WipeoutGround", nil, 14)
check("the board rolling off at 14 m/s without me on it: no speed square", not done(7))
api.onBoard = true
frame(27, "PhysicsGround", nil, 14)
check("... riding it at 14 m/s: ticks", done(7))
