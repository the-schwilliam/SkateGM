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
dofile("../../addon/skategm/lua/skategm_holdline/sh_holdline.lua")
dofile("../../addon/skategm/lua/skategm_holdline/sv_holdline.lua")
local HL = HOLDLINE
local S = HL.session
local A, B, Cc = P("Ann", 1), P("Bob", 2), P("Cat", 3)
local now = 100
local function cmd(p, m) HL.Command(p, m, now) end
local function tick(dt) for _ = 1, math.floor(dt / 0.1 + 0.5) do now = now + 0.1 HL.Tick(now) end end
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
check("a safe moment to pass: rolling on the board", HL.SafeState("PhysicsGround"))
check("... not in the air, grinding, in a manual, bailing or on foot",
	not HL.SafeState("KnownAir") and not HL.SafeState("GrindGround") and not HL.SafeState("ManualGround") and not HL.SafeState("WipeoutGround") and not HL.SafeState("BipedGround"))
check("the line goes round and round", HL.NextIndex(1, 3) == 2 and HL.NextIndex(3, 3) == 1 and HL.NextIndex(1, 1) == 1)
cmd(A, { cmd = "create", turnTime = 10, minSpeed = 60, canSkate = true })
check("hosted: the start where the host stands", S.phase == "lobby" and S.start[1] == 10 and S.turnTime == 10 and S.minSpeed == 60)
cmd(B, { cmd = "join", canSkate = true })
cmd(Cc, { cmd = "join", canSkate = true })
cmd(A, { cmd = "begin" })
check("the host starts the line from the start", S.phase == "countdown" and S.active == A and S.handover.pos[1] == 10)
tick(HL.COUNTDOWN + 0.1)
check("then rides", S.phase == "riding" and S.active == A)
A.SkateGMHips = Vector(300, 20, 0)
cmd(A, { cmd = "pass", pos = { 300, 20, 4 }, yaw = 45, vel = { 200, 0, 0 }, score = 1500 })
check("passing before the time's up: ignored", S.phase == "riding" and S.active == A)
tick(10)
cmd(A, { cmd = "pass", pos = { 300, 20, 4 }, yaw = 45, vel = { 200, 0, 0 }, score = 1500 })
check("time's up and rolling: Bob takes over exactly there, same way, same speed", S.phase == "handover" and S.active == B and S.handover.pos[1] == 300 and S.handover.yaw == 45 and S.handover.vel[1] == 200)
check("... Ann's points join the team's line", S.total == 1500 and S.passes == 1)
tick(HL.HANDOVER + 0.1)
check("held a few seconds, then Bob rides", S.phase == "riding" and S.active == B)
cmd(B, { cmd = "live", pos = { 900, 0, 4 }, yaw = 0, vel = { 150, 0, 0 }, score = 700 })
B.SkateGMHips = Vector(900, 0, 0)
tick(10 + HL.PASS_WAIT + 0.2)
check("no pass from Bob well after his time: it passes from where he last was", S.phase == "handover" and S.active == Cc and S.handover.pos[1] == 900 and S.total == 2200)
tick(HL.HANDOVER + 0.1)
cmd(Cc, { cmd = "bail" })
check("Cat bails: the line's over for everyone", S.phase == "results" and S.over.reason == "bail" and S.over.name == "Cat")
check("... the best line kept", S.best.total == 2200 and S.best.passes == 2)
tick(HL.RESULTS + 0.2)
check("then the lobby", S.phase == "lobby")
cmd(A, { cmd = "begin" })
tick(HL.COUNTDOWN + 0.1)
cmd(A, { cmd = "stall" })
check("slowing to a stop ends it too", S.phase == "results" and S.over.reason == "stall")
tick(HL.RESULTS + 0.2)
cmd(A, { cmd = "begin" })
tick(HL.COUNTDOWN + 0.1)
A.SkateGMHips = Vector(0, 0, 0)
tick(10)
cmd(A, { cmd = "pass", pos = { 5000, 0, 0 }, yaw = 0, vel = { 99999, 0, 0 }, score = 10 })
check("a pass from far from the skater: from the skater instead; speed capped", S.handover.pos[1] == 0 and S.handover.vel[1] <= HL.SPEED_CAP)
tick(HL.HANDOVER + 0.1)
cmd(B, { cmd = "leave" })
check("the one holding the line leaves: it's over", S.phase == "results" and S.over.reason == "left")
