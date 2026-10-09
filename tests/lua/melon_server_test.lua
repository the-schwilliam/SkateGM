dofile("gmock.lua")
SERVER = true
CurTime = CurTime or function() return 0 end
SysTime = SysTime or function() return 0 end
local chats = {}
util = setmetatable({ AddNetworkString = function() end, TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
local states = {}
net = { Start = function() end, WriteString = function(t) states[#states + 1] = t end, Broadcast = function() end, Receive = function() end, ReadString = function() end, Send = function() end }
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
timer = { Simple = function(_, f) f() end }
PrintMessage = function(_, t) chats[#chats + 1] = t end
HUD_PRINTTALK = 3
MASK_SOLID_BRUSHONLY, COLLISION_GROUP_WEAPON = 1, 11
math.NormalizeAngle = math.NormalizeAngle or function(a) return (a + 180) % 360 - 180 end
math.Rand = math.Rand or function(a, b) return a + (b - a) * math.random() end
function IsValid(x) return x ~= nil and (type(x) ~= "table" or not x.gone) end
-- the ground at z 0, open sky above (a roof at z 300 where ROOF says)
ROOF = nil
util.TraceLine = function(t)
	if t.start.z < 0 then return { Hit = true, StartSolid = true, HitPos = t.start, HitNormal = Vector(0, 0, 1) } end
	if t.endpos.z < t.start.z then
		local floor = (ROOF and t.start.z > ROOF) and ROOF or 0
		return { Hit = true, HitPos = Vector(t.start.x, t.start.y, floor), HitNormal = Vector(0, 0, 1) }
	end
	if ROOF and t.start.z < ROOF and t.endpos.z > ROOF then return { Hit = true, HitPos = Vector(t.endpos.x, t.endpos.y, ROOF), HitNormal = Vector(0, 0, -1) } end
	return { Hit = false, HitPos = t.endpos, HitNormal = Vector(0, 0, 0) }
end
MASK_SOLID = 2
local made = {}
ents = { Create = function(class)
	local e = { class = class, pos = Vector(0, 0, 0), nw = {} }
	function e:SetModel(m) self.model = m end
	function e:SetPos(p) self.pos = p end
	function e:GetPos() return self.pos end
	function e:SetAngles() end
	function e:SetNWBool(k, v) self.nw[k] = v end
	function e:Spawn() end
	function e:SetKeyValue(k, v) self.kv = self.kv or {} self.kv[k] = v end
	function e:SetCollisionGroup(g) self.group = g end
	function e:GetPhysicsObject() return { Wake = function() end, SetVelocity = function(_, v) e.vel = v end } end
	function e:Remove() self.gone = true end
	function e:EntIndex() return 500 + #made end
	made[#made + 1] = e
	return e
end }
local skating = {}
SkateGM = { API = { Allowed = function() return true end, IsSkating = function(p) return skating[p] == true end } }
local function Player(id, name)
	local p = { id = id, name = name }
	function p:EntIndex() return self.id end
	function p:UserID() if self.gone then error("NULL entity") end return self.id end
	function p:Nick() return self.name end
	function p:IsAdmin() return self.admin == true end
	function p:GetPos() return self.SkateGMHips or Vector(0, 0, 0) end
	function p:ChatPrint(t) chats[#chats + 1] = self.name .. ": " .. t end
	return p
end
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_melon/sh_melon.lua")
dofile("../../addon/skategm/lua/skategm_melon/sv_melon.lua")
local G = MELON.session
local host, bob, cat = Player(1, "Host"), Player(2, "Bob"), Player(3, "Cat")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
local function lastChat() return chats[#chats] or "" end
local function last() return states[#states] end
math.randomseed(3)
local t = 100

MELON.Command(host, { cmd = "create", pos = { 0, 0, 0 }, centre = { 0, 0, 0 }, radius = 99999, target = 1, yaw = 0, canSkate = true }, t)
check("created; settings kept within limits", G.phase == "lobby" and G.area[4] == MELON.AREA_MAX and G.target == MELON.TARGET_MIN)
MELON.Command(host, { cmd = "settings", target = 30, radius = 1000 }, t)
check("the host changes the time and area", G.target == 30 and G.area[4] == 1000)
MELON.Command(bob, { cmd = "join", canSkate = true }, t)
MELON.Command(cat, { cmd = "join", canSkate = true }, t)
skating[host], skating[bob], skating[cat] = true, true, true
host.SkateGMHips, bob.SkateGMHips, cat.SkateGMHips = Vector(0, 0, 36), Vector(300, 0, 36), Vector(-300, 0, 36)
MELON.Command(host, { cmd = "begin" }, t)
check("start: the countdown", G.phase == "countdown")
t = t + MELON.COUNTDOWN
MELON.Think(t)
check("GO: no melon yet, it drops in a moment", G.phase == "playing" and not IsValid(G.melonEnt) and G.dropTime)
t = t + MELON.FIRST_DROP
MELON.Think(t)
local melon = G.melonEnt
check("the melon drops into the area, from the sky", IsValid(melon) and melon.model == MELON.MODEL and melon.pos.z > 100 and MELON.InArea(G.area, melon.pos) and lastChat():find("loose"))
check("skaters don't collide with it", melon.group == COLLISION_GROUP_WEAPON)
check("nobody can physgun it away", hooks["PhysgunPickup/skategm_melon"](host, melon) == false)
check("nobody can break it", hooks["EntityTakeDamage/skategm_melon"](melon) == true)
melon.pos = Vector(300, 10, 30)
check("too far away to grab it: no", not MELON.Grab(cat, t))
check("Bob skates through it: his", MELON.Grab(bob, t) and G.king == bob and melon.gone and lastChat():find("Bob seized the melon!", 1, true))
check("everyone sees who's King", last().king == 2 and last().melon == nil)
t = t + 1
MELON.Think(t)
check("the King's clock runs", math.abs(G.entries["2"].held - 1) < 1e-6)
bob.SkateGMHips = Vector(5000, 0, 36)
t = t + 1
MELON.Think(t)
check("... but not outside the area", math.abs(G.entries["2"].held - 1) < 1e-6)
bob.SkateGMHips = Vector(300, 0, 36)
cat.SkateGMHips = Vector(320, 0, 36)
check("someone skates into the King: theirs", MELON.Steal(cat, bob, t) and G.king == cat and lastChat():find("Cat seized"))
check("not straight back off them (a moment's grace)", not MELON.Steal(bob, cat, t + 0.5) and G.king == cat)
check("... nor straight back by who lost it", not MELON.Steal(bob, cat, t + MELON.HOLD_GRACE + 0.1) and G.king == cat)
host.SkateGMHips = Vector(310, 0, 36)
check("but anyone else can, after the grace", MELON.Steal(host, cat, t + MELON.HOLD_GRACE + 0.1) and G.king == host)
MELON.Command(cat, { cmd = "outside" }, t)
check("someone not the King out of bounds: the melon stays put", G.king == host)
MELON.Command(host, { cmd = "outside" }, t)
check("the King out of bounds too long: the melon drops back inside the area", G.king == nil and IsValid(G.melonEnt) and lastChat():find("left the area", 1, true))
if IsValid(G.melonEnt) then G.melonEnt:Remove() end
G.king, G.kingSince, G.melonEnt = host, t, nil
t = t + 5
MELON.Think(t)
check("the King bails: the melon drops where they are", MELON.Bail(host, { 310, 0, 36 }, t) and G.king == nil and IsValid(G.melonEnt) and lastChat():find("bailed and dropped"))
check("... and pops up a little", G.melonEnt.vel and G.melonEnt.vel.z > 0)
G.melonEnt.pos = Vector(310, 0, 36)
check("who bailed it can't grab it straight back", not MELON.Grab(host, t + 0.5))
check("... but can a moment later", MELON.Grab(host, t + MELON.DROP_LOCK + 0.1) and G.king == host)
t = t + MELON.DROP_LOCK + 0.1
skating[host] = false
MELON.Think(t + 0.1)
check("the King leaves Skater mode: the melon drops", G.king == nil and IsValid(G.melonEnt))
skating[host] = true
G.melonEnt.pos = Vector(9000, 0, 0)
MELON.Think(t + 1)
MELON.Think(t + 1 + MELON.LOST_AFTER + 0.1)
MELON.Think(t + 2 + MELON.LOST_AFTER + 0.2)
check("a melon that rolls out of the area drops in again", IsValid(G.melonEnt) and MELON.InArea(G.area, G.melonEnt.pos))
t = t + 10
G.melonEnt.pos = Vector(300, 0, 36)
MELON.Grab(bob, t)
G.entries["2"].held = 29.5
MELON.Think(t + 0.6)
check("30 seconds in all with it: the winner", G.phase == "results" and G.winner and G.winner.name == "Bob" and lastChat():find("Bob is the Melon King"))
check("the melon's gone at the end", not IsValid(G.melonEnt))
MELON.Think(t + 0.6 + MELON.RESULTS)
check("then back to the lobby, clocks reset", G.phase == "lobby" and G.entries["2"].held == 0)
skating[host], skating[bob], skating[cat] = true, true, true
MELON.Command(host, { cmd = "begin" }, t + 20)
MELON.Think(t + 20 + MELON.COUNTDOWN)
MELON.Think(t + 20 + MELON.COUNTDOWN + MELON.FIRST_DROP)
G.melonEnt.pos = Vector(300, 0, 36)
MELON.Grab(bob, t + 30)
bob.gone = true
MELON.Think(t + 31)
check("the King disconnects: the melon drops, the game goes on", G.phase == "playing" and G.king == nil and IsValid(G.melonEnt))
cat.gone = true
MELON.Think(t + 32)
check("one skater left: they win", G.phase == "results" and G.winner and G.winner.name == "Host")

-- the melon can't smash, and isn't dropped onto a roof
do
	local area = { 0, 0, 0, 512 }
	local spot = MELON.DropSpot(area)
	check("the melon drops from the drop height over open ground", spot and math.abs(spot.z - (48 + MELON.DROP_HEIGHT - 16)) < 0.01)
	ROOF = 160
	spot = MELON.DropSpot(area)
	check("under a roof it drops from just below the roof, not onto it", spot and spot.z < 160 and spot.z > 0)
	ROOF = nil
	local e = made[#made]
	check("the melon is made unbreakable (it smashed on landing)", e and e.kv and e.kv.physdamagescale == "0" and tonumber(e.kv.minhealthdmg) >= 99999)
end

-- closing a game that's going: one press ends it for everyone
G.phase = "playing"
MELON.Command(host, { cmd = "stop", close = true }, t + 200)
check("Close the game in the middle of one: closed in one go", G.phase == "idle")
