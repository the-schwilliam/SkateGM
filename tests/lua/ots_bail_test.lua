dofile("gmock.lua")
-- mocks
local sent = {}
util = { AddNetworkString = function() end, TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }
net = { Start = function() end, WriteString = function(t) sent[#sent + 1] = t end, Broadcast = function() end, Receive = function() end }
local chatlog = {}
function PrintMessage(_, t) chatlog[#chatlog + 1] = t end
HUD_PRINTTALK = 3
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
timer = { Simple = function() end }
function IsValid(x) return x ~= nil and x.valid ~= false end
string.Comma = function(n) return tostring(n) end
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
dofile("../../addon/skategm/lua/skategm_ots/sh_ots.lua")
dofile("../../addon/skategm/lua/skategm_ots/sv_ots.lua")
local S = OTS.session
local A, B, Cc = P("Ann", 1), P("Bob", 2), P("Cat", 3)
local now = 100
local function cmd(p, m) OTS.Command(p, m, now) end
local function tick(dt) local steps = math.floor(dt / 0.1) for _ = 1, steps do now = now + 0.1 OTS.Tick(now) end end
local function last() return chatlog[#chatlog] or "" end
local function check(label, ok) print(string.format("%-60s %s", label, ok and "OK" or "<-- WRONG")) end


cmd(A, { cmd = "create", turn = 20, rounds = 1, canSkate = true })
check("bail ends a turn: on unless the host turns it off", S.bailEnds == true)
cmd(B, { cmd = "join", canSkate = true })
cmd(A, { cmd = "begin" })
skating[A] = true
cmd(A, { cmd = "ready" })
tick(3.2)
cmd(A, { cmd = "live", score = 800 })
cmd(A, { cmd = "bailed", score = 600 })
check("Ann bails: her turn ends there, what she'd banked counts", S.phase == "between" and S.last.score == 600 and S.last.reason == "bailed")
cmd(A, { cmd = "stop", close = true })
cmd(A, { cmd = "stop" })
cmd(A, { cmd = "create", turn = 20, rounds = 1, bailEnds = false, canSkate = true })
cmd(B, { cmd = "join", canSkate = true })
cmd(A, { cmd = "begin" })
cmd(A, { cmd = "ready" })
tick(3.2)
cmd(A, { cmd = "bailed", score = 600 })
check("... turned off: a bail doesn't end the turn", S.phase == "turn")
