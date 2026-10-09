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
dofile("../../addon/skategm/lua/skategm_hom/sh_hom.lua")
dofile("../../addon/skategm/lua/skategm_bodybingo/sh_bodybingo.lua")
dofile("../../addon/skategm/lua/skategm_bodybingo/sv_bodybingo.lua")
local BB = BODYBINGO
local S = BB.session
local A, B = P("Ann", 1), P("Bob", 2)
local now = 100
local function cmd(p, m) BB.Command(p, m, now) end
local function tick(dt) for _ = 1, math.floor(dt / 0.1) do now = now + 0.1 BB.Tick(now) end end
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local function E(p) return S.entries[SKATEGM_MODES.Key(p)] end
local card = BB.Deal(HOM.PARTS)
local seen, ok = {}, #card == 9
for _, sq in ipairs(card) do if seen[sq.part] or not HOM.PART[sq.part] or sq.level < 1 or sq.level > 3 then ok = false end seen[sq.part] = true end
check("a card: 9 different body parts, each asking Bruised to Broken", ok)
check("an injury ticks a square for that part at least that bad", #BB.Ticks({ { part = "skull", level = 2 } }, {}, "skull", 3) == 1 and #BB.Ticks({ { part = "skull", level = 2 } }, {}, "skull", 1) == 0)
cmd(A, { cmd = "create", time = 120, canSkate = true })
cmd(B, { cmd = "join", canSkate = true })
cmd(A, { cmd = "begin" })
tick(3.2)
check("start: a shared card, then play", S.phase == "playing" and #S.card == 9)
S.card = { { part = "skull", level = 1 }, { part = "neck", level = 2 }, { part = "ribs", level = 3 },
	{ part = "spine", level = 1 }, { part = "pelvis", level = 1 }, { part = "lcollar", level = 1 },
	{ part = "rcollar", level = 1 }, { part = "lhumerus", level = 1 }, { part = "rhumerus", level = 1 } }
cmd(A, { cmd = "hurt", part = "neck", level = 1 })
check("a bruised neck isn't enough for 'Neck: Fractured'", not E(A).marks[2])
cmd(A, { cmd = "hurt", part = "neck", level = 3 })
check("... a broken one is", E(A).marks[2] == true)
cmd(A, { cmd = "hurt", part = "skull", level = 1 })
cmd(A, { cmd = "hurt", part = "ribs", level = 3 })
check("a whole row: BINGO", S.phase == "results" and S.winner and S.winner.name == "Ann")
tick(BB.RESULTS + 1)
cmd(A, { cmd = "begin" })
tick(3.2)
S.card[1] = { part = "skull", level = 1 }
cmd(B, { cmd = "hurt", part = "skull", level = 2 })
tick(120.2)
check("time's up: the most squares wins", S.phase == "results" and S.winner.name == "Bob")
local M = SKATEGM_MODES
check("the start is where the host stood", S.start ~= nil)
local spots = {}
for i = 1, 3 do spots[i] = BODYBINGO.Slot({ 0, 0, 0 }, 90, i, 3) end
check("skaters start side by side across the host's facing", math.abs(spots[1][2]) < 1e-6 and spots[1][1] ~= spots[3][1] and math.abs(spots[2][1]) < 1e-6)
cmd(A, { cmd = "stop", close = true })
cmd(A, { cmd = "create", time = 120, canSkate = true })
cmd(A, { cmd = "begin" })
for _ = 1, 40 do now = now + 0.1 BODYBINGO.Tick(now) end
local pos, yaw = M.RespawnPointFor(A)
check("LB + X while playing: back to the start, not refused", pos ~= nil and math.abs(pos.x - 10) < 1e-6 and yaw == 90)
