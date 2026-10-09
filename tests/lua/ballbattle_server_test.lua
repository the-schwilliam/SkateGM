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
dofile("../../addon/skategm/lua/skategm_ballbattle/sh_ballbattle.lua")
dofile("../../addon/skategm/lua/skategm_ballbattle/sv_ballbattle.lua")
local BB = BALLBATTLE
local S = BB.session
local A, B, Cc = P("Ann", 1), P("Bob", 2), P("Cat", 3)
A.SkateGMHips, B.SkateGMHips, Cc.SkateGMHips = Vector(0, 0, 0), Vector(100, 0, 0), Vector(200, 0, 0)
local now = 100
function CurTime() return now end
local function tick(dt) for _ = 1, math.floor(dt / 0.1) do now = now + 0.1 BB.mode:RunThink(now) ITEMS.server.Think(now) end end
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local function E(p) return S.entries[SKATEGM_MODES.Key(p)] end
local function H(p, m) BB.mode:HandleCommand(p, 10, m, now) end
H(A, { cmd = "create", centre = { 0, 0, 0 }, radius = 2000, time = 120, balls = 3, items = true, canSkate = true })
H(B, { cmd = "join", canSkate = true })
H(Cc, { cmd = "join", canSkate = true })
H(A, { cmd = "begin" })
tick(3.2)
check("everyone starts with 3 balls; items on", S.phase == "playing" and E(A).balls == 3 and S._items ~= nil)
local arena = S._items
arena:Hit(B, A, "rocket")
check("an item hit pops one of Bob's balls", E(B).balls == 2)
H(B, { cmd = "bailed" })
check("... the bail it causes doesn't pop another", E(B).balls == 2)
now = now + 3
H(B, { cmd = "bailed" })
check("a bail of his own later: another one", E(B).balls == 1)
now = now + 3
H(B, { cmd = "bailed" })
check("the last ball gone: out", E(B).out == true)
check("... out players can't be hit any more", not arena:Has(B))
now = now + 3
H(Cc, { cmd = "outside" })
check("out of bounds too long: out, whatever balls are left", E(Cc).out == true and E(Cc).balls == 0)
check("one left with balls: they win", S.phase == "results" and S.winners.names[1] == "Ann")
