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
dofile("../../addon/skategm/lua/skategm_imposter/sh_imposter.lua")
dofile("../../addon/skategm/lua/skategm_imposter/sv_imposter.lua")
local S = IMPOSTER.session
local A, B, Cc, D = P("Ann", 1), P("Bob", 2), P("Cat", 3), P("Dan", 4)
local now = 100
local function cmd(p, m) IMPOSTER.Command(p, m, now) end
local function tick(dt) for _ = 1, math.floor(dt / 0.1) do now = now + 0.1 IMPOSTER.Tick(now) end end
local function last() return chatlog[#chatlog] or "" end
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end

check("targets are round numbers inside the difficulty's range", (function()
	for _ = 1, 200 do
		local t = IMPOSTER.PickTarget("medium")
		if t < 2000 or t > 4000 or t % IMPOSTER.ROUND_TO ~= 0 then return false end
	end
	return true
end)())
check("the default range is 0 - 2,000, and never a target of 0", IMPOSTER.DIFFICULTY_DEFAULT == "easy" and (function()
	for _ = 1, 200 do
		local t = IMPOSTER.PickTarget("easy")
		if t <= 0 or t > 2000 then return false end
	end
	return true
end)())
check("the imposter never goes first (unless allowed)", (function()
	local list = { A, B, Cc, D }
	for _ = 1, 200 do if IMPOSTER.Order(list, A, false)[1] == A then return false end end
	return true
end)())
local top = IMPOSTER.Tally({ [1] = 3, [2] = 3, [4] = 1 })
local tie = IMPOSTER.Tally({ [1] = 3, [2] = 4 })
check("the vote: most votes is out; a tie puts nobody out", top == 3 and tie == nil)

cmd(A, { cmd = "create", turn = 30, difficulty = "easy", canSkate = true })
check("host opens a lobby at their spot", S.phase == "lobby" and S.host == A and S.turn == 30 and S.difficulty == "easy")
cmd(B, { cmd = "join", canSkate = true })
cmd(A, { cmd = "begin" })
check("two players can't start (three needed)", S.phase == "lobby" and last():find("at least 3") ~= nil)
cmd(Cc, { cmd = "join", canSkate = true })
cmd(D, { cmd = "join", canSkate = true })
math.randomseed(7)
cmd(A, { cmd = "begin" })
local imposter = S.imposter
local crewTargets, imposterHas = {}, nil
for p, r in pairs(roles) do
	if p == imposter then imposterHas = r.target else crewTargets[#crewTargets + 1] = r.target end
end
check("everyone gets their role privately: the crew the score, the imposter nothing", roles[imposter] and roles[imposter].imposter == true and imposterHas == 0
	and #crewTargets == 3 and crewTargets[1] == S.target and crewTargets[2] == S.target and crewTargets[3] == S.target)
local pub = IMPOSTER.mode.lastState
check("the public state holds neither the score nor who the imposter is", pub.result == nil and pub.target == nil and pub.imposter == nil)
check("first turn: prep, the rest frozen to watch", S.phase == "prep" and S.active == S.order[1] and S.order[1] ~= imposter)

local scores = {}
for turn = 1, 4 do
	local p = S.active
	skating[p] = true
	cmd(p, { cmd = "ready" })
	tick(3.2)
	if turn == 1 then check("countdown, then the line", S.phase == "turn") end
	if p == imposter then
		cmd(p, { cmd = "landed", score = 0, how = "bail" })
	else
		cmd(p, { cmd = "landed", score = 4000 + turn, how = "land" })
	end
	if turn == 1 then
		check("the line lands: the turn ends, its score kept hidden", S.phase == "between" and IMPOSTER.mode.lastState.last.score == nil)
		cmd(p, { cmd = "landed", score = 99999, how = "land" })
		check("... a second line doesn't count", S.entries[SKATEGM_MODES.Key(p)].score == 4001)
	end
	tick(3.2)
end
check("after everyone's line: the vote, everyone held", S.phase == "vote" and A.frozen and B.frozen)
cmd(A, { cmd = "vote", target = 1 })
check("you can't vote for yourself", S.votes[1] == nil)
for _, p in ipairs({ A, B, Cc, D }) do
	local target = p == imposter and (imposter == B and Cc:EntIndex() or B:EntIndex()) or imposter:EntIndex()
	cmd(p, { cmd = "vote", target = target })
end
tick(0.2)
local r = S.result
check("all voted: the results, the imposter caught", S.phase == "results" and r and r.crewWin == true and r.imposter == imposter:EntIndex() and r.target == S.target)
check("... everyone's line shown, the closest crew line named", #r.lines == 4 and r.closest ~= nil and r.closest ~= imposter:Nick())
tick(IMPOSTER.RESULTS + 1)
check("then back to the lobby for another round, roles cleared", S.phase == "lobby" and S.imposter == nil and #S.players == 4 and not A.frozen)

roles = {}
math.randomseed(3)
cmd(A, { cmd = "begin" })
local imp2 = S.imposter
local p = S.active
skating[p] = true
cmd(p, { cmd = "ready" })
tick(3.2)
tick(30.2)
check("time's up mid-line: a few seconds to land it", S.phase == "finish")
cmd(p, { cmd = "landed", score = 0, how = "none" })
check("... no line going: the turn ends with no line", S.phase == "between" and S.entries[SKATEGM_MODES.Key(p)].how == "no line")
IMPOSTER.Remove(imp2, "left the game", now)
check("the impostor leaving ends it: straight to the results", S.phase == "results" and S.result.why == "the impostor left")
