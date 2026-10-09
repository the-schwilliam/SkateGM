dofile("gmock.lua")
local roles = {}
local cur
util = { AddNetworkString = function() end, TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }
net = { Start = function(n) cur = { name = n } end, WriteString = function() end, WriteBool = function(b) cur.imposter = b end,
	WriteUInt = function(v) cur.target = v end, Send = function(p) if cur and cur.name == "skategm_imposter_role" then roles[p] = cur end end,
	Broadcast = function() end, Receive = function() end }
local chatlog = {}
function PrintMessage(_, t) chatlog[#chatlog + 1] = t end
HUD_PRINTTALK = 3
hook = { Add = function() end }
timer = { Simple = function() end }
function IsValid(x) return x ~= nil and x.valid ~= false end
math.Clamp = function(v, a, b) return math.max(a, math.min(b, v)) end
local skating = {}
local function P(name, id)
	local p = { name = name, id = id, frozen = false, valid = true }
	function p:Nick() return self.name end
	function p:UserID() return self.id end
	function p:EntIndex() return self.id end
	function p:GetPos() return { x = 10, y = 20, z = 0 } end
	function p:EyeAngles() return { y = 90 } end
	function p:Freeze(b) self.frozen = b end
	function p:ChatPrint(t) chatlog[#chatlog + 1] = self.name .. ": " .. t end
	function p:IsAdmin() return false end
	return p
end
SkateGM = { API = { Allowed = function() return true end, IsSkating = function(p) return skating[p] == true end } }
SERVER = true
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_ghostwriter/sh_ghostwriter.lua")
dofile("../../addon/skategm/lua/skategm_ghostwriter/sv_ghostwriter.lua")
local GW = GHOSTWRITER
local S = GW.session
local A, B, Cc = P("Ann", 1), P("Bob", 2), P("Cat", 3)
local now = 100
local function cmd(p, m) GW.Command(p, m, now) end
local function tick(dt) for _ = 1, math.floor(dt / 0.1) do now = now + 0.1 GW.Tick(now) end end
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local function E(p) return S.entries[SKATEGM_MODES.Key(p)] end
cmd(A, { cmd = "create", runTime = 20, canSkate = true })
cmd(B, { cmd = "join", canSkate = true })
cmd(A, { cmd = "begin" })
check("needs three", S.phase == "lobby")
cmd(Cc, { cmd = "join", canSkate = true })
cmd(A, { cmd = "begin" })
tick(3.2)
check("everyone runs at once", S.phase == "running")
tick(20.2)
check("then the first replay", S.phase == "replay")
local pub = GW.mode.lastState
check("... its number and whose clip to play (no name in the state)", pub.replay and pub.replay.index == 1 and pub.replay.total == 3 and pub.reveal == nil)
local runner = S.order[1]
tick(20 + GW.REPLAY_GAP + 0.2)
check("then the guessing", S.phase == "guess")
local byEnt = { [1] = A, [2] = B, [3] = Cc }
cmd(byEnt[runner], { cmd = "guess", target = runner == 1 and 2 or 1 })
check("the skater of that run can't guess on it", S.guesses[runner] == nil)
local others = {}
for e, p in pairs(byEnt) do if e ~= runner then others[#others + 1] = p end end
cmd(others[1], { cmd = "guess", target = runner })
local wrong = 0
for e in pairs(byEnt) do if e ~= runner and e ~= others[2]:EntIndex() then wrong = e end end
cmd(others[2], { cmd = "guess", target = wrong })
tick(0.2)
check("all guessed: straight on to the next run, no answer yet", S.phase == "replay" and S.replayIndex == 2 and S.reveal == nil)
check("... and nobody's points show", GW.mode.lastState.players[1].points == nil and E(others[1]).points == 0)
for _ = 1, 2 do
	tick(20 + GW.REPLAY_GAP + 0.2)
	tick(GW.GUESS_TIME + 0.2)
end
check("every run guessed: the answers, from the first run", S.phase == "reveal" and S.reveal.ent == runner and S.reveal.index == 1 and #S.reveal.right == 1)
check("... a point for the right guess, one to the skater for fooling the other", E(others[1]).points == 1 and E(byEnt[runner]).points == 1 and E(others[2]).points == 0)
check("... everyone's pick is in it", #S.reveal.picks == 2)
tick(GW.REVEAL + 0.2)
check("then the next run's answer", S.phase == "reveal" and S.reveal.index == 2)
tick(GW.REVEAL + 0.2)
tick(GW.REVEAL + 0.2)
check("after every answer: the results", S.phase == "results" and S.winners ~= nil)
