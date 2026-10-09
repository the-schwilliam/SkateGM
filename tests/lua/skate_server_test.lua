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
dofile("../../addon/skategm/lua/skategm_skate/sh_skate.lua")
dofile("../../addon/skategm/lua/skategm_skate/sv_skate.lua")
local S = SKATE.session
local A, B, Cc = P("Ann", 1), P("Bob", 2), P("Cat", 3)
local now = 100
local function cmd(p, m) SKATE.Command(p, m, now) end
local function tick(dt) for _ = 1, math.floor(dt / 0.1) do now = now + 0.1 SKATE.Tick(now) end end
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local function E(p) return S.entries[SKATEGM_MODES.Key(p)] end
local function go(p, landed, tricks)
	skating[p] = true
	cmd(p, { cmd = "ready" })
	tick(3.2)
	cmd(p, { cmd = "attempt", landed = landed, tricks = tricks })
end

check("a match needs every trick of the set, in any order, any case", SKATE.Matches({ "Kickflip", "50-50" }, { "50-50", "kickflip", "Manual" }) and not SKATE.Matches({ "Kickflip", "50-50" }, { "Kickflip" }))
check("letters spell the word", SKATE.Letters(3) == "S.K.A" and SKATE.Letters(0) == "")
cmd(A, { cmd = "create", time = 30, canSkate = true })
cmd(B, { cmd = "join", canSkate = true })
cmd(Cc, { cmd = "join", canSkate = true })
math.randomseed(1)
cmd(A, { cmd = "begin" })
local setter = S.setter
check("start: the first setter's go", S.phase == "prep" and S.active == setter)
go(setter, true, { "Kickflip", "Kickflip", "50-50" })
check("the setter lands kickflip + 50-50: that's the set (repeats once)", S.set and #S.set == 2 and S.set[1] == "Kickflip" and S.phase == "between")
tick(SKATE.BETWEEN + 0.2)
local first = S.active
check("then the next player has to match it", S.phase == "prep" and first ~= setter)
go(first, true, { "50-50", "Kickflip", "Manual" })
check("... they land both (plus more): no letter", E(first).letters == 0)
tick(SKATE.BETWEEN + 0.2)
local second = S.active
go(second, false, {})
check("the other one bails: S", E(second).letters == 1)
tick(SKATE.BETWEEN + 0.2)
check("everyone's had a go: the setter sets again", S.active == setter and S.set == nil)
go(setter, false, {})
check("the setter bails their set: no letter, the next one sets", E(setter).letters == 0 and S.setter ~= setter)
E(second).letters = 4
tick(SKATE.BETWEEN + 0.2)
local newSetter = S.active
go(newSetter, true, { "Heelflip" })
tick(SKATE.BETWEEN + 0.2)
while S.phase == "prep" and S.active ~= second do
	go(S.active, true, { "Heelflip" })
	tick(SKATE.BETWEEN + 0.2)
end
if S.active == second then go(second, true, { "Kickflip" }) end
check("a fifth letter: out", E(second).out == true)
local alive = 0
for _, p in ipairs({ A, B, Cc }) do if not E(p).out then alive = alive + 1 end end
check("... the game goes on with the two left", alive == 2 and S.phase ~= "results")
SKATE.Remove(newSetter == second and setter or newSetter, "left the game", now)
check("one left: they win", S.phase == "results" and S.winner ~= nil)
tick(SKATE.RESULTS + 1)
check("then the lobby, letters cleared", S.phase == "lobby" and (E(A) == nil or E(A).letters == 0))
