dofile("gmock.lua")
SERVER = true
local T = 100
function CurTime() return T end
function FrameTime() return 0.05 end
function ErrorNoHalt(e) print("ERROR " .. tostring(e)) end
local sent = {}
local cur
util = setmetatable({ AddNetworkString = function() end, TableToJSON = function(t) return t end, JSONToTable = function(t) return t end,
	TraceLine = function() return { Hit = false } end }, { __index = util })
net = { Start = function() cur = {} end, WriteString = function(t) cur.msg = t end,
	Send = function(p) sent[#sent + 1] = { to = p, msg = cur.msg } end, Broadcast = function() sent[#sent + 1] = { msg = cur.msg } end,
	Receive = function() end }
hook = { Add = function() end }
timer = { Simple = function() end }
MASK_SOLID_BRUSHONLY, MASK_PLAYERSOLID = 1, 2
function IsValid(x) return x ~= nil end
local ents = {}
local function P(id, pos)
	local p = { id = id, SkateGMHips = pos }
	function p:EntIndex() return self.id end
	function p:UserID() return self.id end
	function p:Nick() return "p" .. self.id end
	function p:GetPos() return self.SkateGMHips end
	function p:EyeAngles() return Angle(0, 0, 0) end
	ents[id] = p
	return p
end
function Entity(i) return ents[i] end
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
SKATEGM_MODES.Ground = function(x, y, z) return z end
dofile("../../addon/skategm/lua/skategm_items/sh_items.lua")
dofile("../../addon/skategm/lua/skategm_items/sv_items.lua")
for _, f in ipairs({ "rocket", "grenade", "cone", "crowbar", "physgun" }) do dofile("../../addon/skategm/lua/skategm_itemdefs/" .. f .. ".lua") end
local IT, SV = ITEMS, ITEMS.server
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local function to(p, k) for i = #sent, 1, -1 do if sent[i].to == p and sent[i].msg.k == k then return sent[i].msg end end end
local function fx(item, field) for i = #sent, 1, -1 do local m = sent[i].msg if m.k == "fx" and m.item == item and (not field or m[field]) then return m end end end
local function run(seconds) for _ = 1, math.floor(seconds / 0.05) do T = T + 0.05 SV.Think(T) end end

check("five items registered, each with a model", #IT.order == 5 and IT.Get("rocket").model and IT.Get("crowbar").uses == 3)
local A, B, Cc = P(1, Vector(0, 0, 0)), P(2, Vector(400, 0, 0)), P(3, Vector(0, 3000, 0))
local players = { A, B }
local hits = {}
local arena = SV.Open(nil, nil, { centre = Vector(0, 0, 0), radius = 1500, players = players, crates = 10,
	onHit = function(victim, attacker, id) hits[#hits + 1] = { victim = victim, attacker = attacker, id = id } end })
check("an arena: its crates spread over the area, sent to everyone", #arena.crates == 10 and sent[#sent].msg.k == "arena" and #sent[#sent].msg.crates == 10)
local inside = true
for _, c in ipairs(arena.crates) do if math.sqrt(c.pos[1] ^ 2 + c.pos[2] ^ 2) > 1500 then inside = false end end
check("... all inside the area", inside)

local function only(id) for _, k in ipairs(IT.order) do IT.defs[k].weight = k == id and 1 or 0 end end
local function give(p, id) only(id) local c = arena.crates[1] c.alive = true p.SkateGMHips = Vector(c.pos[1], c.pos[2], c.pos[3] + IT.CRATE_FLOAT) SV.Pick(p, arena, 1, T) end
local home = Vector(0, 0, 0)
give(A, "rocket")
check("skating through a crate breaks it and hands over an item", arena.holding[A] and arena.holding[A].id == "rocket" and not arena.crates[1].alive)
check("... everyone hears who holds what", sent[#sent].msg.k == "hold" and sent[#sent].msg.e == 1 and sent[#sent].msg.id == "rocket")
arena.crates[1].alive = false
run(IT.CRATE_RESPAWN + 0.2)
check("the crate comes back after a while", arena.crates[1].alive)
A.SkateGMHips = home
local far = arena.crates[2]
SV.Pick(B, arena, 2, T)
check("... a crate too far from you can't be taken", far.alive and arena.holding[B] == nil)

SV.Use(A, arena, { target = 3 })
check("the rocket can't be fired at someone outside the game", arena.holding[A] ~= nil and fx("rocket") == nil)
SV.Use(A, arena, { target = 2 })
check("fired at Bob: a rocket flies (everyone sees it), the item is used up", fx("rocket", "from") and arena.holding[A] == nil)
run(1.0)
check("... it lands: Bob is knocked off, the game hears who hit whom", to(B, "hit") and hits[1] and hits[1].victim == B and hits[1].attacker == A and hits[1].id == "rocket")

T = T + 3
give(A, "physgun")
A.SkateGMHips = home
SV.Use(A, arena, { target = 2 })
check("physics gun: Bob frozen for two seconds, a beam for everyone to see", to(B, "freeze") and to(B, "freeze").s == 2 and fx("physgun", "from"))

T = T + 3
give(A, "crowbar")
A.SkateGMHips, B.SkateGMHips = home, Vector(80, 0, 0)
arena.hist[A] = { dir = Vector(1, 0, 0) }
SV.Use(A, arena, {})
run(0.3)
check("crowbar: the swing knocks off Bob in front", #hits == 2 and hits[2].id == "crowbar")
check("... two swings left", arena.holding[A] and arena.holding[A].uses == 2)
SV.Use(A, arena, {}) SV.Use(A, arena, {})
run(0.3)
check("... three swings and it's gone", arena.holding[A] == nil)

T = T + 3
give(A, "cone")
A.SkateGMHips = home
arena.hist[A] = { dir = Vector(1, 0, 0) }
SV.Use(A, arena, {})
local cone = arena.objects.cones[1]
check("traffic cone: dropped behind you", cone and cone.pos.x < -20)
run(0.2)
check("... you don't trip on your own cone straight away", #arena.objects.cones == 1)
B.SkateGMHips = cone.pos + Vector(0, 0, 20)
run(0.1)
check("... Bob skates into it: he bails, the cone breaks", #arena.objects.cones == 0 and hits[#hits].id == "cone" and hits[#hits].victim == B)

T = T + 3
give(A, "grenade")
A.SkateGMHips, B.SkateGMHips = home, Vector(300, 0, 40)
arena.hist[A] = { dir = Vector(1, 0, 0) }
local before = #hits
SV.Use(A, arena, {})
run(1.5)
check("grenade: thrown ahead, it goes off reaching Bob and knocks him off", #hits == before + 1 and hits[#hits].id == "grenade" and fx("grenade", "boom"))

T = T + 3
give(A, "grenade")
B.SkateGMHips = Vector(0, 2500, 0)
before = #hits
SV.Use(A, arena, {})
run(3.5)
check("... nobody near: it goes off by itself, hurting nobody far away", #hits == before and #arena.objects.grenades == 0)

T = T + 3
give(A, "grenade")
local flat = util.TraceLine
util.TraceLine = function(t)
	if t.endpos.z < 0 and t.start.z >= 0 then
		local f = t.start.z / (t.start.z - t.endpos.z)
		return { Hit = true, HitPos = t.start + (t.endpos - t.start) * f, HitNormal = Vector(0, 0, 1) }
	end
	return { Hit = false }
end
local G = IT.Get("grenade")
local _, land = G.Predict(home, Vector(1, 0, 0))
B.SkateGMHips = land + Vector(120, 0, 40)
A.SkateGMHips = home
arena.hist[A] = { dir = Vector(1, 0, 0), pos = home }
before = #hits
local thrown = T
SV.Use(A, arena, {})
local boomAt
for _ = 1, 60 do
	T = T + 0.05
	SV.Think(T)
	if not boomAt and #arena.objects.grenades == 0 then boomAt = T end
end
util.TraceLine = flat
check("... it goes off as soon as it lands, long before the fuse", boomAt and boomAt - thrown < 1.6 and #hits == before + 1 and hits[#hits].victim == B)

T = T + 3
before = #hits
arena:Hit(B, A, "rocket")
arena:Hit(B, A, "rocket")
check("one hit at a time (a second straight after doesn't count)", #hits == before + 1)

SV.Close(arena)
check("closing: the arena goes, everyone told", SV.arenas[arena.id] == nil and sent[#sent].msg.k == "close")
