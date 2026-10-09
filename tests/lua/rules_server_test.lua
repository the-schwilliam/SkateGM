dofile("gmock.lua")
local states = {}
util = { AddNetworkString = function() end, TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }
net = { Start = function() end, WriteString = function(t) states[#states + 1] = t end, Broadcast = function() end, Receive = function() end }
function PrintMessage() end
hook = { Add = function() end }
timer = { Simple = function() end }
function IsValid(x) return x ~= nil end
SERVER = true
function CurTime() return 1 end
SkateGM = { API = { Allowed = function() return true end, IsSkating = function() return true end } }
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
local M = SKATEGM_MODES
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local function P(id) local p = { id = id } function p:EntIndex() return id end function p:UserID() return id end function p:Nick() return "p" .. id end function p:ChatPrint() end return p end
local G = { phase = "idle" }
local mode = M.Register({ id = "rulestest", title = "Rules test" })
mode:UseSessions(G)
mode:OnCommand(function(ply, m)
	if m.cmd == "create" then
		G.phase, G.host, G.players = "lobby", ply, { ply }
		mode:Broadcast({ phase = G.phase }, 0)
	end
end)
local A = P(1)
mode:HandleCommand(A, 10, { cmd = "create", rules = { rocket = false, hover = true } }, 1)
local st = states[#states]
check("a game hosted with the rocket off: its state says so", st and st.rules and st.rules.rocket == false and st.rules.hover == "on")
check("rocket fuel kept only when it's one of the choices, and only with the rocket on",
	M.CleanRules({ rocket = "on", fuel = 3 }).fuel == 3 and M.CleanRules({ rocket = "on", fuel = 7 }).fuel == nil and M.CleanRules({ rocket = false, fuel = 3 }).fuel == nil)
check("rules are cleaned (only rocket / hover; off unless switched on)", M.CleanRules({ rocket = "force", junk = 1 }).rocket == "force" and M.CleanRules({}).hover == false and M.CleanRules({ rocket = "on" }).rocket == "on" and M.CleanRules(nil) == nil)
local invites = {}
local wrote = {}
net.WriteString = function(t) wrote[#wrote + 1] = t states[#states + 1] = t end
net.Send = function(p) invites[#invites + 1] = { to = p, data = wrote } wrote = {} end
local B2 = P(2)
function B2:IsPlayer() return true end
function Entity(i) if i == 2 then return B2 end end
wrote = {}
mode:HandleCommand(A, 10, { cmd = "_invite", target = 2 }, 2)
check("the host invites Bob: Bob gets the mode, the game and who asked", #invites == 1 and invites[1].to == B2 and invites[1].data[1] == "rulestest" and invites[1].data[3] == "p1")
G.phase = "playing"
mode:HandleCommand(A, 10, { cmd = "_invite", target = 2 }, 3)
check("... not once the game has started", #invites == 1)
