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
local balls = {}
ents = { Create = function(class)
	local b = { valid = true, class = class, speed = 500, pos = Vector(0, 0, 0) }
	function b:SetPos(p) self.pos = p end
	function b:SetAngles(a) self.ang = a end
	function b:SetSkater(p) self.skater = p end
	function b:Spawn() end
	function b:Launch(v, damping) self.vel, self.damping = v, damping end
	function b:Speed() return self.speed end
	function b:GetPos() return self.pos end
	function b:Remove() self.valid = false end
	function b:GetPhysicsObject() return { EnableMotion = function() end, valid = true } end
	function b:EntIndex() return 77 end
	balls[#balls + 1] = b
	return b
end }
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_boardgolf/sh_boardgolf.lua")
dofile("../../addon/skategm/lua/skategm_boardgolf/sv_boardgolf.lua")
local BG = BOARDGOLF
local S = BG.session
local A, B = P("Ann", 1), P("Bob", 2)
local now = 100
local function cmd(p, m) BG.Command(p, m, now) end
local function tick(dt) for _ = 1, math.floor(dt / 0.1 + 0.5) do now = now + 0.1 BG.Tick(now) end end
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local function E(p) return S.entries[SKATEGM_MODES.Key(p)] end
local function shoot(p) cmd(p, { cmd = "ready" }) tick(BG.COUNTDOWN + 0.1) end
local function release(p, x, y) p.SkateGMHips = Vector(x, y, 0) cmd(p, { cmd = "release", pos = { x, y, 0 }, ang = { 0, 30, 0 }, vel = { 400, 0, 0 } }) end
local function rest(x, y) local b = balls[#balls] b.pos, b.speed = Vector(x, y, 0), 0 tick(BG.REST_TIME + 0.2) end
check("in the cup: resting inside its radius, near its height", BG.InCup({ 10, 0, 0 }, { 0, 0, 0 }, 32) and not BG.InCup({ 40, 0, 0 }, { 0, 0, 0 }, 32) and not BG.InCup({ 0, 0, 200 }, { 0, 0, 0 }, 32))
check("par grows with the distance", BG.Par(500) == 2 and BG.Par(2000) == 4 and BG.Par(99999) == 6)
check("farthest from the cup shoots first; holed-out skaters don't", BG.NextUp({ { lie = { 100, 0, 0 } }, { lie = { 900, 0, 0 } }, { lie = { 2000, 0, 0 }, holed = true } }, { 0, 0, 0 }).lie[1] == 900)
check("the host's par, or Auto (from the distance)", BG.ParChoice(5) == 5 and BG.ParChoice(0) == 0 and BG.ParChoice(99) == 0)
cmd(A, { cmd = "create", canSkate = true })
check("no cup placed: can't host", S.phase == "idle")
cmd(A, { cmd = "create", cup = { 1010, 20, 0 }, cupSize = "small", shotTime = 4, maxStrokes = 4, friction = 75, canSkate = true })
check("hosted: the tee where the host stands, the cup where they put it, a par", S.phase == "lobby" and S.tee[1] == 10 and S.cup[1] == 1010 and S.par == 3)
cmd(B, { cmd = "join", canSkate = true })
skating[A], skating[B] = true, true
cmd(A, { cmd = "begin" })
check("first a flyover from the tee to the cup, everyone held still", S.phase == "flyover" and A.frozen and B.frozen)
tick(BG.FlyTime(BG.Distance(S.tee, S.cup)) + 0.2)
check("everyone starts on the tee; one shoots, the rest are frozen", S.phase == "prep" and S.active and E(A).lie[1] == 10 and (A.frozen or B.frozen))
local first = S.active
shoot(first)
check("the shot", S.phase == "shot")
release(first, 300, 20)
local ball = balls[#balls]
check("let go: a ball where the board was, its angle and speed, the host's grip", S.phase == "roll" and ball.pos.x == 300 and ball.ang.y == 30 and ball.vel.x == 400 and ball.damping == 75 and ball.skater == first)
check("... its number goes to everyone (for the camera)", BG.Broadcast and S.board == ball)
tick(1)
check("still rolling: no result yet", S.phase == "roll")
rest(600, 20)
check("the ball stops 410 short: that's the lie, 1 stroke; the ball stays put while it shows", E(first).lie[1] == 600 and E(first).strokes == 1 and S.last.distance == 410 and ball.valid)
tick(BG.BETWEEN + 0.1)
check("... and goes with the next shot", not ball.valid)
local second = S.active
check("then the one farther away (still on the tee)", second ~= first and E(second).strokes == 0)
shoot(second)
release(second, 900, 20)
local over = balls[#balls]
over.pos, over.speed = Vector(1005, 20, 0), 900
tick(0.3)
check("rolling fast over the cup: it doesn't drop in", S.phase == "roll" and not E(second).holed)
over.speed = 200
tick(0.2)
check("slowly over it: it drops in (held, sinking)", S.phase == "roll" and S.sinkAt ~= nil)
tick(BG.SINK_TIME + 0.1)
check("in the cup in one!", E(second).holed and S.last.result == "holed" and E(second).strokes == 1)
tick(BG.BETWEEN + 0.1)
check("only the one still out keeps shooting", S.active == first)
shoot(first)
first.SkateGMHips = Vector(0, 0, 0)
cmd(first, { cmd = "release", pos = { 5000, 0, 0 }, vel = { 0, 0, 0 } })
check("a release far from where the server saw the skater: the ball starts at the skater instead", balls[#balls].pos.x == 0)
rest(650, 0)
tick(BG.BETWEEN + 0.1)
shoot(first)
tick(4 + BG.RELEASE_GRACE + 0.2)
check("no release at all: the stroke counts when the shot runs out", E(first).strokes == 3 and S.last.result == "lost")
tick(BG.BETWEEN + 0.1)
shoot(first)
release(first, 700, 20)
balls[#balls].speed = 300
tick(BG.SETTLE + 0.2)
check("a ball that never stops: where it is when the roll time's up", E(first).holed and E(first).picked)
tick(BG.BETWEEN + 0.1)
check("everyone in: the fewest strokes wins", S.phase == "results" and S.winners.names[1] == (second == A and "Ann" or "Bob") and S.winners.strokes == 1)
check("board friction: the host's choice, or normal", BG.Friction(150) == 150 and BG.Friction(7) == BG.FRICTION_DEFAULT and BG.Friction(0) == 0)
cmd(A, { cmd = "stop", close = true })
cmd(A, { cmd = "stop", close = true })
cmd(A, { cmd = "create", cup = { 500, 0, 0 }, radius = 90, canSkate = true })
check("the cup's size from the placer", S.radius == 90 and BG.InCup({ 580, 0, 0 }, S.cup, S.radius))
