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
dofile("../../addon/skategm/lua/skategm_bullseye/sh_bullseye.lua")
dofile("../../addon/skategm/lua/skategm_bullseye/sv_bullseye.lua")
local BE = BULLSEYE
local S = BE.session
local A, B = P("Ann", 1), P("Bob", 2)
local now = 100
local function cmd(p, m) BE.Command(p, m, now) end
local function tick(dt) for _ = 1, math.floor(dt / 0.1) do now = now + 0.1 BE.Tick(now) end end
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local function E(p) return S.entries[SKATEGM_MODES.Key(p)] end
local w = BE.RingWidth("medium")
check("rings from the middle: gold 6, purple 3, blue 2, green 1, then nothing",
	BE.Score({ 0, 0, 0 }, w * 0.5, 0, w) == 6 and BE.Score({ 0, 0, 0 }, w * 1.5, 0, w) == 3 and BE.Score({ 0, 0, 0 }, 0, w * 2.5, w) == 2
	and BE.Score({ 0, 0, 0 }, w * 3.5, 0, w) == 1 and BE.Score({ 0, 0, 0 }, w * 4.5, 0, w) == 0)
cmd(A, { cmd = "create", canSkate = true, rounds = 2, time = 20 })
check("no target placed: can't host", S.phase == "idle")
cmd(A, { cmd = "create", target = { 1000, 0, 0 }, size = "medium", rounds = 2, time = 20, canSkate = true })
check("hosted: the start where the host stands, the target where they put it", S.phase == "lobby" and S.target[1] == 1000 and S.start.x == 10)
cmd(B, { cmd = "join", canSkate = true })
skating[A], skating[B] = true, true
cmd(A, { cmd = "begin" })
check("turn by turn: the first jump", S.phase == "prep" and S.active == A and B.frozen)
cmd(A, { cmd = "ready" })
tick(3.2)
cmd(A, { cmd = "landed", pos = { 1000 + w * 0.3, 0, 0 } })
check("Ann lands in the gold: 6", E(A).total == 6 and S.last.ring == "gold" and #S.shots == 1)
cmd(A, { cmd = "landed", pos = { 1000, 0, 0 } })
check("... and that's locked in (a second landing doesn't count)", E(A).total == 6)
tick(BE.BETWEEN + 0.2)
check("then Bob's jump", S.active == B)
cmd(B, { cmd = "ready" })
tick(3.2)
cmd(B, { cmd = "landed", nozone = true, pos = { 1000, 0, 0 } })
check("Bob touches the no-zone: nothing, even with a landing in the rings sent along", E(B).total == 0 and S.last.how == "nozone")
tick(BE.BETWEEN + 0.2)
check("round 2: Ann again, the marks cleared", S.round == 2 and S.active == A and #S.shots == 0)
cmd(A, { cmd = "ready" })
tick(3.2)
tick(20.2)
check("time's up in the air: a few seconds to land", S.phase == "finish")
cmd(A, { cmd = "landed", pos = { 1000 + w * 2.2, 0, 0 } })
check("... landed in the blue: +2", E(A).total == 8)
tick(BE.BETWEEN + 0.2)
cmd(B, { cmd = "ready" })
tick(3.2)
cmd(B, { cmd = "landed", pos = { 1000 + w * 3.9, 0, 0 } })
tick(BE.BETWEEN + 0.2)
check("after every round: the winner", S.phase == "results" and S.winners.names[1] == "Ann" and S.winners.points == 8)
cmd(A, { cmd = "stop", close = true })
cmd(A, { cmd = "stop", close = true })
cmd(A, { cmd = "create", target = { 0, 0, 0 }, width = 120, rounds = 1, time = 20, canSkate = true })
check("the target's size from the placer: its ring width", S.width == 120)
cmd(A, { cmd = "stop", close = true })
cmd(A, { cmd = "create", target = { 0, 0, 0 }, width = 99999, rounds = 1, time = 20, canSkate = true })
check("... held to its limits", S.width == BE.WIDTH_MAX)
