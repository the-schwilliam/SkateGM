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
dofile("../../addon/skategm/lua/skategm_rocketroyale/sh_rocketroyale.lua")
dofile("../../addon/skategm/lua/skategm_rocketroyale/sv_rocketroyale.lua")
local RR = ROCKETROYALE
local S = RR.session
local A, B, Cc = P("Ann", 1), P("Bob", 2), P("Cat", 3)
local now = 100
local function cmd(p, m) RR.Command(p, m, now) end
local function tick(dt) for _ = 1, math.floor(dt / 0.1) do now = now + 0.1 RR.Tick(now) end end
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
check("start slots: side by side, centred on the start", math.abs(select(2, RR.SlotOffset(1, 3, 0)) + select(2, RR.SlotOffset(3, 3, 0))) < 1e-6 and math.abs(select(2, RR.SlotOffset(2, 3, 0))) < 1e-6)
cmd(A, { cmd = "create", time = 60, canSkate = true })
check("the rocket is forced on for this game (whatever the client sent)", S._boardRules and S._boardRules.rocket == "force")
cmd(B, { cmd = "join", canSkate = true })
cmd(Cc, { cmd = "join", canSkate = true })
skating[A], skating[B], skating[Cc] = true, true, true
cmd(A, { cmd = "begin" })
tick(3.2)
check("countdown, then rockets on", S.phase == "playing")
tick(2)
cmd(B, { cmd = "bailed" })
check("a bail: out, with how long they lasted", S.entries[SKATEGM_MODES.Key(B)].out and S.entries[SKATEGM_MODES.Key(B)].lasted >= 2)
skating[Cc] = false
tick(2)
check("leaving Skater mode: out too", S.entries[SKATEGM_MODES.Key(Cc)].out == true)
check("one riding: they win", S.phase == "results" and #S.winners == 1 and S.winners[1] == "Ann")
tick(RR.RESULTS + 1)
skating[Cc] = true
cmd(A, { cmd = "begin" })
tick(3.2 + 61)
check("time's up with several riding: they all rode it out", S.phase == "results" and #S.winners == 3)
