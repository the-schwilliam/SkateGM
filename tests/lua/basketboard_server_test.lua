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
dofile("../../addon/skategm/lua/skategm_basketboard/sh_basketboard.lua")
dofile("../../addon/skategm/lua/skategm_basketboard/sv_basketboard.lua")
local BB = BASKETBOARD
local S = BB.session
local A, B = P("Ann", 1), P("Bob", 2)
local now = 100
local function cmd(p, m) BB.Command(p, m, now) end
local function tick(dt) for _ = 1, math.floor(dt / 0.1) do now = now + 0.1 BB.Tick(now) end end
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local function E(p) return S.entries[SKATEGM_MODES.Key(p)] end
local hoop = { 0, 0, 100 }
check("through the rim from above, inside it: in", BB.Through({ 5, 0, 120 }, { 5, 0, 90 }, hoop, 30) == true)
check("... outside the rim: not", BB.Through({ 50, 0, 120 }, { 50, 0, 90 }, hoop, 30) == false)
check("... from below: not (unless either way is asked)", BB.Through({ 0, 0, 90 }, { 0, 0, 120 }, hoop, 30) == false and BB.Through({ 0, 0, 90 }, { 0, 0, 120 }, hoop, 30, true) == true)
check("... where it crossed the rim's plane counts, not where it ended", BB.Through({ 0, 0, 101 }, { 200, 0, 99 }, hoop, 30) == false and BB.Through({ -60, 0, 130 }, { 60, 0, 70 }, hoop, 30) == true)
check("the no-zone: on the ground under the hoop, within its size", BB.InZone({ 0, 0, 0 }, 120, 50, 0, 10) and not BB.InZone({ 0, 0, 0 }, 120, 200, 0, 10) and not BB.InZone({ 0, 0, 0 }, 120, 50, 0, 300) and not BB.InZone({ 0, 0, 0 }, 0, 0, 0, 0))
check("... touching it scores nothing", not BB.SCORING.nozone)
local M = SKATEGM_MODES
check("rolling on it (the board just over its surface): touching", M.TouchingNoZone({ SKATEBOARD_ROOT = Vector(30, 0, 4), HIPS = Vector(30, 0, 40) }, { 0, 0, 0 }, 0, 120))
check("riding a platform over it (32 up): not touching", not M.TouchingNoZone({ SKATEBOARD_ROOT = Vector(30, 0, 36), HIPS = Vector(30, 0, 72), RIGHTFOOT = Vector(30, 0, 38) }, { 0, 0, 0 }, 0, 120))
check("... nor a floor 24 under it", not M.TouchingNoZone({ SKATEBOARD_ROOT = Vector(30, 0, -20), HIPS = Vector(30, 0, 16), RIGHTFOOT = Vector(30, 0, -18) }, { 0, 0, 0 }, 0, 120))
check("lying on it after a bail: touching", M.TouchingNoZone({ HIPS = Vector(30, 0, 10) }, { 0, 0, 0 }, 0, 120, true))
check("the hoop faces the start, turned as the host asks", math.abs(BB.Facing({ 0, 0, 0 }, { 100, 0 }, 0)) < 1e-6 and math.abs(BB.Facing({ 0, 0, 0 }, { 100, 0 }, 90) - 90) < 1e-6)
cmd(A, { cmd = "create", rounds = 2, time = 20, canSkate = true })
check("no hoop placed: can't host", S.phase == "idle")
cmd(A, { cmd = "create", hoop = { pos = { 510, 20, 4 }, yaw = 135, scale = 52, lift = 80 }, rounds = 2, time = 20, canSkate = true })
check("hosted: start where the host stands, the hoop where they put it, as big and as high, facing their way",
	S.phase == "lobby" and S.start.x == 10 and S.hoop[1] == 510 and S.hoop[3] == 84 and S.radius == 52 and S.facing == 135)
cmd(A, { cmd = "stop", close = true })
cmd(A, { cmd = "create", hoop = { pos = { 510, 20, 4 }, scale = 9999, lift = -5 }, rounds = 2, time = 20, canSkate = true })
check("sizes out of range are held to the limits; no direction: it faces the start", S.radius == BB.RADIUS_MAX and S.height == BB.LIFT_MIN and math.abs(S.facing - 180) < 1)
cmd(B, { cmd = "join", canSkate = true })
skating[A], skating[B] = true, true
cmd(A, { cmd = "begin" })
check("turn by turn: Ann first, Bob frozen", S.phase == "prep" and S.active == A and B.frozen)
cmd(A, { cmd = "ready" })
tick(3.2)
check("countdown, then the turn", S.phase == "turn")
cmd(A, { cmd = "result", how = "basket" })
check("Ann's board in, Ann out: 1 point", E(A).total == 1 and S.last.how == "basket")
cmd(A, { cmd = "result", how = "basket" })
check("... once a turn", E(A).total == 1)
tick(BB.BETWEEN + 0.2)
cmd(B, { cmd = "result", how = "basket" })
check("a result before the turn starts doesn't count", E(B).total == 0)
cmd(B, { cmd = "ready" })
tick(3.2)
cmd(B, { cmd = "result", how = "player" })
check("Bob dunks himself: a point too", E(B).total == 1 and S.last.how == "player")
tick(BB.BETWEEN + 0.2)
check("round 2: Ann again", S.round == 2 and S.active == A)
cmd(A, { cmd = "ready" })
tick(3.2)
cmd(A, { cmd = "result", how = "nonsense" })
check("an unknown outcome is ignored", S.phase == "turn")
tick(20.2)
check("time's up: a few seconds to let the board go", S.phase == "finish")
tick(BB.FINISH + BB.WATCH + 0.2)
check("... then out of time: nothing", S.last.how == "out of time" and E(A).total == 1)
tick(BB.BETWEEN + 0.2)
cmd(B, { cmd = "ready" })
tick(3.2)
cmd(B, { cmd = "result", how = "miss" })
tick(BB.BETWEEN + 0.2)
check("after every round: the most baskets wins", S.phase == "results" and S.winners.names[1] == "Ann" and S.winners.points == 1)
