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
util.TraceLine = function(t) if t.endpos.z < t.start.z then return { Hit = true, HitPos = Vector(t.start.x, t.start.y, 0) } end return { Hit = false, HitPos = t.endpos } end
local made = {}
ents = { Create = function(class)
	local e = { class = class, pos = Vector(0, 0, 0), nw = {} }
	function e:SetModel(m) self.model = m end
	function e:SetPos(p) self.pos = p end
	function e:GetPos() return self.pos end
	function e:SetAngles() end
	function e:SetNWBool(k, v) self.nw[k] = v end
	function e:Spawn() end
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
dofile("../../addon/skategm/lua/skategm_royale/sh_royale.lua")
dofile("../../addon/skategm/lua/skategm_royale/sv_royale.lua")
local G = ROYALE.session
local host, bob, cat, dan = Player(1, "Host"), Player(2, "Bob"), Player(3, "Cat"), Player(4, "Dan")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
local function lastChat() return chats[#chats] or "" end
local t = 100
local function last() return states[#states] end
ROYALE.Command(host, { cmd = "create", pos = { 0, 0, 0 }, runTime = 20, yaw = 0, canSkate = true }, t)
check("bail ends a run: on unless the host turns it off", G.bailEnds == true)
for _, p in ipairs({ bob, cat }) do ROYALE.Command(p, { cmd = "join", canSkate = true }, t) end
skating[host], skating[bob], skating[cat] = true, true, true
ROYALE.Command(host, { cmd = "begin" }, t)
t = t + ROYALE.COUNTDOWN ROYALE.Think(t)
ROYALE.Command(bob, { cmd = "bailed", score = 300 }, t + 2)
local bobRow
for _, p in ipairs(last().players) do if p.ent == 2 then bobRow = p end end
check("Bob bails: his run is over (marked done, his score kept)", bobRow and bobRow.done and G.entries[SKATEGM_MODES.Key(bob)].score == 300)
ROYALE.Command(bob, { cmd = "score", score = 9999 }, t + 19)
check("... a later score doesn't change it", G.entries[SKATEGM_MODES.Key(bob)].score == 300)
ROYALE.Command(host, { cmd = "bailed", score = 10 }, t + 3)
ROYALE.Command(cat, { cmd = "bailed", score = 20 }, t + 4)
ROYALE.Think(t + 4)
check("everyone bailed: straight to the replays", G.phase == "replays")
