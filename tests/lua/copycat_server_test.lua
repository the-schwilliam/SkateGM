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
dofile("../../addon/skategm/lua/skategm_copycat/sh_copycat.lua")
dofile("../../addon/skategm/lua/skategm_copycat/sv_copycat.lua")
local CC = COPYCAT
local S = CC.session
local A, B, Cc = P("Ann", 1), P("Bob", 2), P("Cat", 3)
local now = 100
local function cmd(p, m) CC.Command(p, m, now) end
local motion = {}
local function tick(dt)
	for _ = 1, math.floor(dt / 0.05 + 0.5) do
		now = now + 0.05
		for p, f in pairs(motion) do local x, y, z = f(now) p.SkateGMHips = { x = x, y = y, z = z } end
		CC.Tick(now)
	end
end
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local function E(p) return S.entries[SKATEGM_MODES.Key(p)] end
local line = {}
for i = 0, 20 do line[#line + 1] = { i * 20, 0, 0 } end
check("the same line: 100", CC.Match(line, line) == 100)
local off = {}
for i, p in ipairs(line) do off[i] = { p[1], p[2] + 96, p[3] } end
check("96 units to the side all along: half (normal judging)", CC.Match(line, off, 192) == 50)
check("... strict judging scores it lower, loose higher", CC.Match(line, off, 128) < 50 and CC.Match(line, off, 320) > 50)
local half = {}
for i = 1, 11 do half[i] = line[i] end
check("only half the line skated: less than all of it", CC.Match(line, half) < 100)
local long = {}
for i = 0, 100 do long[#long + 1] = { i * 20, 0, 0 } end
check("standing still on a real-length line: nothing near", CC.Match(long, { { 0, 0, 0 }, { 0, 0, 0 } }, 192) < 15)
local close = {}
for i, p in ipairs(long) do close[i] = { p[1], p[2] + 60, p[3] } end
close[1], close[2] = { 3000, 3000, 0 }, { 3000, 3000, 0 }
check("a copy 60 off the line with two stray samples: still a good score", CC.Match(long, close, 192) >= 65)
local slow = {}
for i = 1, 80 do slow[i] = long[i] end
check("the same line, but slower (four fifths of it): most of the points", CC.Match(long, slow, 192) >= 75)
check("no copy recorded: 0", CC.Match(line, {}) == 0)
cmd(A, { cmd = "create", runTime = 5, judging = 192, canSkate = true })
cmd(B, { cmd = "join", canSkate = true })
cmd(Cc, { cmd = "join", canSkate = true })
cmd(A, { cmd = "begin" })
check("the host sets the first line", S.phase == "leadcount" and S.leader == 1 and #S.copiers == 2)
local t0
motion[A] = function(t) t0 = t0 or t return (t - t0) * 100, 0, 0 end
tick(CC.COUNTDOWN + 0.1)
check("then Ann's line", S.phase == "lead")
tick(5.1)
check("then everyone else copies", S.phase == "copycount")
check("... Ann's line was followed (hips sampled)", #S.paths[1] > 30)
motion[A] = nil
local t1
motion[B] = function(t) t1 = t1 or t return (t - t1) * 100, 0, 0 end
motion[Cc] = function(t) return 0, 300, 0 end
tick(CC.COUNTDOWN + 0.1)
check("both copy at once", S.phase == "copy")
tick(5.1)
check("then the replays: one copy at a time, with both lines", S.phase == "replay" and S.replayIndex == 1 and #S.paths[2] > 30 and Public == nil)
check("Bob skated the same line: a high score, Cat stood off to the side: 0", S.scores[2] >= 90 and S.scores[3] == 0)
tick(5 + CC.REPLAY_GAP + 0.1)
check("after the replay: Bob's score, added", S.phase == "score" and S.last.name == "Bob" and E(B).points == S.scores[2])
tick(CC.SCORE + 0.1)
check("then Cat's replay", S.phase == "replay" and S.replayIndex == 2)
tick(5 + CC.REPLAY_GAP + 0.1 + CC.SCORE + 0.1)
check("then Bob sets the next line, Ann and Cat copy", S.phase == "leadcount" and S.leader == 2 and #S.copiers == 2 and S.copiers[1] == 1)
tick(CC.COUNTDOWN + 0.1)
cmd(A, { cmd = "bailed" })
check("a copier's bail during the setter's line: ignored", S.phase == "lead")
tick(1.5)
cmd(B, { cmd = "bailed" })
check("the setter bails: the line ends there, the copies start", S.phase == "copycount")
check("... and get as long as the line took (at least a few seconds)", S.lineTime == CC.MIN_LINE)
cmd(Cc, { cmd = "leave" })
check("someone leaves mid-game: it goes on with the rest", S.phase ~= "idle" and #S.copiers == 1)
motion = {}
for _ = 1, 400 do if S.phase == "results" then break end tick(0.5) end
check("every player has set a line: the results", S.phase == "results" and S.winners.names[1] == "Bob")
