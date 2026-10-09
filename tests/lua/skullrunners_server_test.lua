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
function ErrorNoHalt(e) print("ERROR " .. tostring(e)) end
util.TraceLine = function() return { Hit = false } end
MASK_PLAYERSOLID, MASK_SOLID_BRUSHONLY = 1, 2
function FrameTime() return 0.1 end
SKATEGM_MODES.Ground = function(x, y, z) return z end
dofile("../../addon/skategm/lua/skategm_items/sh_items.lua")
dofile("../../addon/skategm/lua/skategm_items/sv_items.lua")
dofile("../../addon/skategm/lua/skategm_itemdefs/rocket.lua")
dofile("../../addon/skategm/lua/skategm_skullrunners/sh_skullrunners.lua")
dofile("../../addon/skategm/lua/skategm_skullrunners/sv_skullrunners.lua")
local SR = SKULLRUNNERS
local S = SR.session
local A, B = P("Ann", 1), P("Bob", 2)
A.SkateGMHips, B.SkateGMHips = Vector(0, 0, 0), Vector(100, 0, 0)
local now = 100
function CurTime() return now end
local function cmd(p, m) SR.Command(p, m, now) end
local function tick(dt) for _ = 1, math.floor(dt / 0.1) do now = now + 0.1 SR.mode:RunThink(now) ITEMS.server.Think(now) end end
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local function E(p) return S.entries[SKATEGM_MODES.Key(p)] end
local function count() local n = 0 for _ in pairs(S.skulls or {}) do n = n + 1 end return n end
SR.mode:HandleCommand(A, 10, { cmd = "create", centre = { 0, 0, 0 }, radius = 2000, time = 60, skulls = 20, items = true, canSkate = true }, now)
SR.mode:HandleCommand(B, 10, { cmd = "join", canSkate = true }, now)
SR.mode:HandleCommand(A, 10, { cmd = "begin" }, now)
check("start: 20 skulls spread over the area", count() == 20)
tick(3.2)
check("countdown, then play; items on: an arena with crates", S.phase == "playing" and S._items and #S._items.crates > 0)
local id, k = next(S.skulls)
A.SkateGMHips = Vector(k[1], k[2], k[3] + SR.FLOAT)
SR.mode:HandleCommand(A, 10, { cmd = "grab", id = id }, now)
check("skate through a skull: it's yours, and another appears (still 20 about)", E(A).skulls == 1 and S.skulls[id] == nil and count() == 20)
local id2, k2 = next(S.skulls)
A.SkateGMHips = Vector(k2[1] + 500, k2[2], k2[3])
SR.mode:HandleCommand(A, 10, { cmd = "grab", id = id2 }, now)
check("... one too far away can't be taken", E(A).skulls == 1 and S.skulls[id2] ~= nil)
E(A).skulls = 5
SR.mode:HandleCommand(A, 10, { cmd = "bailed" }, now)
check("a bail drops 3 of your skulls around you, for anyone", E(A).skulls == 2 and count() == 23)
SR.mode:HandleCommand(A, 10, { cmd = "bailed" }, now)
check("... not again straight away (one bail, one drop)", E(A).skulls == 2)
tick(60.2)
check("time: the most skulls wins", S.phase == "results" and S.winners.names[1] == "Ann")
check("... and the items are gone with the game", S._items == nil and next(ITEMS.server.arenas) == nil)
